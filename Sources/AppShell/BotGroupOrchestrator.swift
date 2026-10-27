import Foundation
import os
import AgentRuntime
import CoreModel
import Persistence
import SocketServer

private let botGroupLog = Logger(subsystem: "io.remotecode.agent", category: "bot.group")

/// Runs group conversations. The room thread holds the transcript and never
/// runs a provider; each participant answers on its own hidden member thread
/// (its own runtime, brain and VM). Turns run one at a time per group, settle
/// only from their own run's finish, and every room row change is published
/// once as `agent.message.appended` or `agent.messages.removed`, every turn change once as
/// `bot.group.turn.updated`.
@MainActor
final class BotGroupOrchestrator: AgentRunObserver {
    struct SendReceipt: Equatable {
        let groupID: BotGroupID
        let roundID: BotGroupRoundID
        let roomThreadID: AgentThreadID
        let userMessageID: AgentMessageID
        let turns: [BotGroupTurn]
        /// The user line and waiting rows this send wrote (empty for a
        /// replayed `submitKey`: read the rows back by id).
        var roomMessages: [AgentMessage] = []
    }

    enum SendError: LocalizedError, Equatable {
        case emptyMessage
        case attachmentsUnsupported
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .emptyMessage: return "Write a message first."
            case .attachmentsUnsupported: return "Attachments are not supported in group conversations yet."
            case .rejected(let message): return message
            }
        }
    }

    private let botStore: BotStore
    private let threadRepo: AgentThreadRepository
    private let runRepo: AgentRunRepository
    private let messageRepo: AgentMessageRepository
    private let checkpointRepo: AgentTurnCheckpointRepository
    private let queuedMessageRepo: AgentQueuedMessageRepository
    private let coordinator: AgentRunCoordinator
    private let appSupportDirectory: URL
    weak var router: AppCommandRouter?

    /// Docker up and the bot's container provisioned; nil on success. Tests
    /// replace it so no Docker is needed.
    var vmPreflight: ((BotID) async -> String?)?
    /// Every published turn change, after its event (group attention).
    var onTurnPublished: ((BotGroupTurn) -> Void)?
    /// Groups whose pump loop is running; a second pump call is a no-op
    /// because the running loop re-reads the turns after every await.
    private var pumpingGroups: Set<BotGroupID> = []
    /// Runs this orchestrator started for a turn and has not settled. Every
    /// run finish in the app reaches `settle`; any other run returns there
    /// without touching SQLite.
    private var ownedRunIDs: Set<AgentRunID> = []
    /// The room watermark each owned run's prompt read through. It moves only
    /// when the run settles as completed: a failed, interrupted or stopped run
    /// never answered those messages, so its retry (or the bot's next turn)
    /// must read them again.
    private var seenThroughOnCompletion: [AgentRunID: (id: AgentMessageID, createdAt: Date)] = [:]

    init(
        botStore: BotStore,
        threadRepo: AgentThreadRepository,
        runRepo: AgentRunRepository,
        messageRepo: AgentMessageRepository,
        checkpointRepo: AgentTurnCheckpointRepository,
        queuedMessageRepo: AgentQueuedMessageRepository,
        coordinator: AgentRunCoordinator,
        appSupportDirectory: URL
    ) {
        self.botStore = botStore
        self.threadRepo = threadRepo
        self.runRepo = runRepo
        self.messageRepo = messageRepo
        self.checkpointRepo = checkpointRepo
        self.queuedMessageRepo = queuedMessageRepo
        self.coordinator = coordinator
        self.appSupportDirectory = appSupportDirectory
        coordinator.addObserver(self)
    }

    deinit {
        coordinator.removeObserver(self)
    }

    // MARK: - Groups

    /// Creates the quiet room thread (no workspace) and the group with one
    /// hidden member conversation per participant.
    func createGroup(
        title: String,
        teamID: BotTeamID? = nil,
        policy: BotGroupPolicy = .roundtable,
        leadBotID: BotID? = nil,
        maxAutoHops: Int = BotGroupConversation.defaultMaxAutoHops,
        participantBotIDs: [BotID]
    ) async throws -> BotGroupConversation {
        guard let router else { throw BotStoreError.invalidRow("Bot runtime is unavailable") }
        let provider = AgentProvider.defaultProvider
        let room = try router.createAgentThread(
            workspace: nil,
            title: title,
            provider: provider,
            model: BotsViewModel.defaultModel(for: provider),
            permissionMode: .fullAccess,
            reasoningEffort: .medium,
            routingConfiguration: nil,
            quiet: true
        )
        do {
            return try botStore.createGroup(
                title: title,
                teamID: teamID,
                roomThreadID: room.id,
                policy: policy,
                leadBotID: leadBotID,
                maxAutoHops: maxAutoHops,
                participantBotIDs: participantBotIDs
            )
        } catch {
            try? await router.deleteAgentThread(thread: room.id)
            throw error
        }
    }

    // MARK: - Send

    /// Writes the user line, the round's turns and one waiting row per turn
    /// on the calling turn, then starts the round off it. A retried send with
    /// the same `submitKey` returns the first send's receipt.
    @discardableResult
    func send(
        groupID: BotGroupID,
        text: String,
        submitKey: String? = nil,
        attachments: [AgentAttachment] = [],
        now: Date = Date()
    ) throws -> SendReceipt {
        guard attachments.isEmpty else { throw SendError.attachmentsUnsupported }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw SendError.emptyMessage }
        guard let group = try botStore.group(id: groupID) else { throw BotStoreError.notFound }
        let existingTurns = try botStore.listGroupTurns(groupID: groupID)
        if let submitKey,
           let receipt = try replayedReceipt(group: group, turns: existingTurns, submitKey: submitKey, text: message) {
            schedulePump(groupID)
            return receipt
        }

        let participants = try activeParticipantBots(groupID: groupID)
        let turnsToPlan: [BotGroupTurnPlanner.PlannedTurn]
        switch BotGroupTurnPlanner.planUserRound(
            text: message,
            participants: participants,
            policy: group.policy,
            leadBotID: group.leadBotID
        ) {
        case .rejected(let rejection): throw SendError.rejected(rejection.message)
        case .turns(let planned): turnsToPlan = planned
        }

        let roundID = BotGroupRoundID()
        let userMessage = AgentMessage(threadId: group.roomThreadID, role: .user, content: message, createdAt: now)
        var ordinal = (existingTurns.map(\.ordinal).max() ?? 0) + 1
        let turns = turnsToPlan.map { planned -> BotGroupTurn in
            defer { ordinal += 1 }
            return BotGroupTurn(
                groupID: groupID,
                roundID: roundID,
                triggerMessageID: userMessage.id,
                botID: planned.botID,
                ordinal: ordinal,
                hop: planned.hop,
                submitKey: submitKey,
                createdAt: now,
                updatedAt: now
            )
        }
        let botsByID = Dictionary(participants.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = waitingRows(for: turns, roomThreadID: group.roomThreadID, bots: botsByID, after: now)
        // One transaction: the turns (which validate the participants, so a
        // refused send writes nothing), the user line and the waiting rows.
        // A failed write or a crash never leaves turns that would answer a
        // message the room does not show.
        try botStore.insertGroupTurns(turns) {
            try self.messageRepo.append(userMessage)
            for row in rows { try self.messageRepo.append(row) }
        }
        publishRow(userMessage)
        rows.forEach(publishRow)
        turns.forEach { publishTurn($0, roomThreadID: group.roomThreadID) }

        // A new user message replaces what is still unstarted in older rounds;
        // a running turn finishes first.
        let supersession = BotGroupTurnPlanner.supersede(existingTurns + turns, newRoundID: roundID)
        for turn in existingTurns + turns where supersession.cancelledTurnIDs.contains(turn.id) {
            move(
                turn,
                from: BotGroupTurn.State.pending,
                to: .cancelled,
                roomThreadID: group.roomThreadID,
                outcome: .note(Self.supersededNote)
            )
        }

        schedulePump(groupID)
        return SendReceipt(
            groupID: groupID,
            roundID: roundID,
            roomThreadID: group.roomThreadID,
            userMessageID: userMessage.id,
            turns: turns,
            roomMessages: [userMessage] + rows
        )
    }

    /// The receipt of an earlier send with `submitKey`. Rows that send did not
    /// get to write (it failed after storing its turns) are written now.
    private func replayedReceipt(
        group: BotGroupConversation,
        turns: [BotGroupTurn],
        submitKey: String,
        text: String
    ) throws -> SendReceipt? {
        let round = turns.filter { $0.submitKey == submitKey && $0.hop == 0 }
        guard let first = round.first, let userMessageID = first.triggerMessageID else { return nil }
        let roundTurns = turns.filter { $0.roundID == first.roundID }
        if try !messageRepo.exists(id: userMessageID) {
            try writeRoomRow(AgentMessage(
                id: userMessageID,
                threadId: group.roomThreadID,
                role: .user,
                content: text,
                createdAt: first.createdAt
            ))
        }
        let pending = round.filter { !$0.state.isTerminal }
        let missing = try pending.filter { try !messageRepo.exists(id: $0.roomMessageID) }
        if !missing.isEmpty {
            let bots = Dictionary(
                try activeParticipantBots(groupID: group.id).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for row in waitingRows(for: missing, roomThreadID: group.roomThreadID, bots: bots, after: first.createdAt) {
                try writeRoomRow(row)
            }
        }
        return SendReceipt(
            groupID: group.id,
            roundID: first.roundID,
            roomThreadID: group.roomThreadID,
            userMessageID: userMessageID,
            turns: roundTurns
        )
    }

    // MARK: - Stop

    /// Cancels every unstarted turn of the group and stops the running one.
    /// Returns the turns it cancelled.
    @discardableResult
    func stop(groupID: BotGroupID) -> [BotGroupTurn] {
        guard let group = try? botStore.group(id: groupID) else { return [] }
        let roomThreadID = group.roomThreadID
        let pending = (try? botStore.listGroupTurns(groupID: groupID, states: BotGroupTurn.State.pending)) ?? []
        let rows = Dictionary(
            pending.map { ($0.id, roomRow(for: $0, roomThreadID: roomThreadID, outcome: .note(Self.stoppedNote))) },
            uniquingKeysWith: { first, _ in first }
        )
        let cancelled: [BotGroupTurn]
        do {
            cancelled = try botStore.cancelPendingGroupTurns(groupID: groupID) { turns in
                for turn in turns { if let row = rows[turn.id] { try self.messageRepo.append(row) } }
            }
        } catch {
            botGroupLog.error("bot.group.stop_failed group=\(groupID.value.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            cancelled = []
        }
        for turn in cancelled {
            if let row = rows[turn.id] { publishRow(row) }
            publishTurn(turn, roomThreadID: roomThreadID)
        }
        var stopped = cancelled
        let running = (try? botStore.listGroupTurns(groupID: groupID, states: [.running])) ?? []
        for turn in running {
            guard let runID = turn.memberRunID,
                  let moved = move(
                    turn,
                    from: [.running],
                    to: .cancelled,
                    expectedMemberRunID: runID,
                    roomThreadID: roomThreadID,
                    outcome: .note(Self.stoppedNote)
                  ) else { continue }
            stopped.append(moved)
            ownedRunIDs.remove(runID)
            seenThroughOnCompletion.removeValue(forKey: runID)
            coordinator.stopRun(runID)
            if let memberThread = memberThreadID(groupID: groupID, botID: turn.botID) {
                // A start still being prepared has no run to stop yet.
                coordinator.stopRun(threadId: memberThread)
            }
        }
        return stopped
    }

    // MARK: - Retry

    /// Puts a failed or interrupted turn back in the queue: its room row
    /// shows waiting again and the turn runs when the group is free.
    @discardableResult
    func retry(turnID: BotGroupTurnID, groupID: BotGroupID) throws -> BotGroupTurn {
        guard let turn = try botStore.groupTurn(id: turnID), turn.groupID == groupID,
              let group = try botStore.group(id: groupID) else { throw BotStoreError.notFound }
        guard turn.state == .failed || turn.state == .interrupted else {
            throw SendError.rejected("Only a failed or interrupted turn can be retried.")
        }
        guard try activeParticipantBots(groupID: groupID).contains(where: { $0.id == turn.botID }) else {
            throw SendError.rejected("That bot is no longer in this group.")
        }
        // The turn keeps its place, so it would run ahead of a newer
        // message's turns and answer out of order.
        let unsettled = try botStore.listGroupTurns(groupID: groupID, states: BotGroupTurn.State.pending + [.running])
        guard !unsettled.contains(where: { $0.roundID != turn.roundID && $0.ordinal > turn.ordinal }) else {
            throw SendError.rejected("Bots are still answering a newer message. Retry when they finish.")
        }
        guard let moved = move(
            turn,
            from: [.failed, .interrupted],
            to: .planned,
            clearMemberRunID: true,
            clearError: true,
            roomThreadID: group.roomThreadID,
            outcome: .waiting
        ) else {
            throw SendError.rejected("This turn changed on the Mac. Refresh and try again.")
        }
        schedulePump(groupID)
        return moved
    }

    // MARK: - Relaunch

    /// A turn that was running when the app closed is interrupted (never re-run
    /// automatically); planned and VM-waiting turns resume.
    func reconcileAfterRelaunch() {
        let running = (try? botStore.listGroupTurns(groupID: nil, states: [.running])) ?? []
        var groups = Set<BotGroupID>()
        for turn in running {
            groups.insert(turn.groupID)
            if let runID = turn.memberRunID,
               let memberThread = memberThreadID(groupID: turn.groupID, botID: turn.botID),
               coordinator.activeRunId(threadId: memberThread) == runID {
                ownedRunIDs.insert(runID)
                continue
            }
            guard let group = try? botStore.group(id: turn.groupID) else { continue }
            move(
                turn,
                from: [.running],
                to: .interrupted,
                expectedMemberRunID: turn.memberRunID,
                error: Self.interruptedError,
                roomThreadID: group.roomThreadID,
                outcome: .needsAttention
            )
        }
        let pending = (try? botStore.listGroupTurns(groupID: nil, states: BotGroupTurn.State.pending)) ?? []
        groups.formUnion(pending.map(\.groupID))
        groups.forEach(schedulePump)
    }

    // MARK: - D12 hand-off

    /// Called when a bot's VM is handed to `memberThreadID`: starts the group
    /// turn waiting for it. False when the thread has no waiting group turn.
    func resumeWaitingTurn(memberThreadID: AgentThreadID) async -> Bool {
        guard router != nil,
              let conversation = try? botStore.conversationLinked(to: memberThreadID),
              let groupID = conversation.groupID,
              let waiting = try? botStore.listGroupTurns(groupID: groupID, states: [.waitingForBot]),
              waiting.contains(where: { $0.botID == conversation.botID }) else { return false }
        await pump(groupID)
        return true
    }

    // MARK: - Turn loop

    private func schedulePump(_ groupID: BotGroupID) {
        // The turns run after the send's reply: their events are lifecycle,
        // never part of the receipt of the RPC that scheduled them.
        EventBus.outsideMutationCapture {
            Task { @MainActor [weak self] in await self?.pump(groupID) }
        }
    }

    /// Starts the group's next turn when none is running. Turns are strictly
    /// sequential: a turn waiting for its bot's VM holds the ones after it.
    private func pump(_ groupID: BotGroupID) async {
        guard !pumpingGroups.contains(groupID) else { return }
        pumpingGroups.insert(groupID)
        defer { pumpingGroups.remove(groupID) }
        while let turns = try? botStore.listGroupTurns(
            groupID: groupID, states: [.planned, .waitingForBot, .running]
        ),
            !turns.contains(where: { $0.state == .running }),
            let head = turns.first {
            guard await start(head) else { return }
        }
    }

    /// Starts one turn. Returns false when the loop must stop (the turn waits
    /// for its bot's VM, or another start took it); true when the turn left
    /// the pending states and the next one may be considered.
    private func start(_ turn: BotGroupTurn) async -> Bool {
        guard let router,
              let group = try? botStore.group(id: turn.groupID) else { return false }
        let roomThreadID = group.roomThreadID
        // True when the turn failed here; false when it had already moved on
        // (the loop stops instead of retrying a turn it cannot change).
        func fail(_ message: String, runID: AgentRunID?) -> Bool {
            if let runID { ownedRunIDs.remove(runID) }
            return move(
                turn,
                from: runID == nil ? BotGroupTurn.State.pending : [.running],
                to: .failed,
                expectedMemberRunID: runID,
                error: message,
                roomThreadID: roomThreadID,
                outcome: .needsAttention
            ) != nil
        }

        guard let bot = try? botStore.get(id: turn.botID), bot.deletedAt == nil,
              let revisionID = bot.currentRevisionID,
              let revision = try? botStore.getRevision(id: revisionID) else {
            return fail("This bot is no longer available.", runID: nil)
        }
        let member: (conversation: BotConversation, thread: AgentThread)
        do {
            member = try ensureMemberThread(group: group, bot: bot, revision: revision, router: router)
        } catch {
            return fail(Self.describe(error), runID: nil)
        }
        let threadID = member.thread.id
        let onVM = member.thread.executionTarget == .vm

        // A rebuild or stop holds the bot's VM: wait, persisted.
        if onVM, let holder = BotVMRunRegistry.shared.blocker(botID: bot.id, threadID: threadID) {
            if turn.state != .waitingForBot {
                move(turn, from: [.planned], to: .waitingForBot, roomThreadID: roomThreadID)
            }
            router.waitForBotVM(botID: bot.id, thread: threadID, holder: holder)
            return false
        }
        if coordinator.activeRunId(threadId: threadID) != nil
            || coordinator.hasPendingProviderStart(threadId: threadID)
            || coordinator.hasProviderSession(threadId: threadID) {
            return fail("\(bot.name) is busy in its private thread. Retry when it finishes.", runID: nil)
        }

        let runID = AgentRunID()
        guard move(
            turn,
            from: BotGroupTurn.State.pending,
            to: .running,
            memberRunID: runID,
            clearError: true,
            roomThreadID: roomThreadID
        ) != nil else { return false }
        ownedRunIDs.insert(runID)

        if onVM {
            let failure: String?
            if let vmPreflight {
                failure = await vmPreflight(bot.id)
            } else {
                failure = await router.botVMPreflight(bot.id, workspace: nil, threadID: threadID)
            }
            if let failure { return fail(failure, runID: runID) }
        }
        guard stillRunning(turn.id, runID: runID) else { return true }

        let routing = BotDeskRouting(thread: member.thread)
        let model = routing.resolvedModel(defaultModel: BotsViewModel.defaultModel(for:))
        let inGuest = routing.provider == .distill
            && ((try? threadRepo.guestPlacement(of: threadID)) ?? nil)?.runsInGuest == true
        let participants = (try? activeParticipantBots(groupID: group.id)) ?? [bot]
        let watermark = (try? botStore.listGroupParticipants(groupID: group.id, includeLeft: true))?
            .first { $0.botID == bot.id }
        let composition = BotGroupPromptComposer.compose(
            groupTitle: group.title,
            me: bot,
            participants: participants,
            roomMessages: (try? messageRepo.list(threadId: roomThreadID)) ?? [],
            seenMessageID: watermark?.seenRoomMessageID,
            seenCreatedAt: watermark?.seenRoomCreatedAt,
            groupTurns: (try? botStore.listGroupTurns(groupID: group.id)) ?? []
        )
        let home = BotHome(appSupportDirectory: appSupportDirectory, bot: bot)
        let memoryAllowed: Bool
        do {
            memoryAllowed = try botStore.globalMemoryUnavailableReason(botID: bot.id, threadID: threadID) == nil
        } catch {
            return fail(Self.describe(error), runID: runID)
        }
        var receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: composition.prompt,
            memoryFiles: memoryAllowed ? ((try? home.readBootstrapMemory()) ?? []).map {
                BotMemoryFileText(path: $0.path, body: $0.body)
            } : [],
            skills: (try? botStore.listSkillBindings(botID: bot.id)) ?? [],
            ownedSkills: ((try? home.listOwnedSkills()) ?? []).map {
                BotOwnedSkillText(slug: $0.slug, body: $0.body)
            },
            routines: (try? botStore.listRoutines(botID: bot.id)) ?? [],
            browser: (try? BotBrowserStore(appSupportDirectory: appSupportDirectory).loadTarget(botID: bot.id)) ?? nil,
            conversationID: member.conversation.id,
            liveRunMode: routing.permissionMode,
            runProvider: routing.provider,
            runModel: model,
            runsInGuest: inGuest
        )
        try? FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
        do {
            let result = try await router.sendAgentMessage(
                thread: threadID,
                text: BotsViewModel.supervisedRunPrompt(
                    userText: composition.prompt,
                    compiledPayload: receipt.compiledPayload,
                    provider: routing.provider,
                    executionTarget: member.thread.executionTarget,
                    runsInGuest: inGuest,
                    importMacFiles: { [botStore, appSupportDirectory] urls in
                        let resource = try botStore.guestResourceID(botID: bot.id, threadID: threadID)
                        return try BotGuestHome.importFiles(urls, appSupport: appSupportDirectory, botID: resource)
                    }
                ),
                provider: routing.provider,
                model: model,
                permissionMode: routing.permissionMode,
                reasoningEffort: routing.reasoningEffort,
                serviceTier: routing.serviceTier,
                modelSelection: routing.modelSelection,
                providerInstanceId: routing.providerInstanceID,
                requestedRunID: runID,
                executionCwdOverride: home.root.path,
                allowProviderCatalogListingDuringPreflight: false
            )
            guard result.status != .queued else {
                // The thread turned busy after the check: the compiled turn must
                // never run later as if the user had typed it. Cancelled the way
                // the user cancels one, so iOS drops the queued row it was sent.
                if let queued = result.queuedMessage { _ = try? router.cancelAgentQueuedMessage(id: queued.id) }
                return fail("\(bot.name) is busy in its private thread. Retry when it finishes.", runID: runID)
            }
            guard result.runId == runID else {
                return fail("\(bot.name) could not start its turn.", runID: runID)
            }
        } catch let busy as BotVMBusyError {
            // The VM was taken between the check and the start.
            ownedRunIDs.remove(runID)
            if move(
                turn,
                from: [.running],
                to: .waitingForBot,
                expectedMemberRunID: runID,
                clearMemberRunID: true,
                roomThreadID: roomThreadID
            ) != nil {
                router.waitForBotVM(botID: bot.id, thread: threadID, holder: busy.holder)
            }
            return false
        } catch {
            return fail(Self.describe(error), runID: runID)
        }
        if !stillRunning(turn.id, runID: runID), coordinator.activeRunId(threadId: threadID) == runID {
            // Stopped while the start was in flight.
            coordinator.stopRun(runID)
        }
        if let seenID = composition.lastSeenMessageID, let seenAt = composition.lastSeenCreatedAt {
            let current = try? botStore.groupTurn(id: turn.id)
            if current?.memberRunID == runID, current?.state == .running {
                seenThroughOnCompletion[runID] = (seenID, seenAt)
            } else if current?.memberRunID == runID, current?.state == .completed {
                // The run settled while its start was still returning.
                try? botStore.setGroupParticipantWatermark(
                    groupID: group.id, botID: bot.id, messageID: seenID, createdAt: seenAt
                )
            }
        }
        receipt.runID = runID
        _ = try? botStore.insertContextReceipt(receipt)
        return true
    }

    private func stillRunning(_ turnID: BotGroupTurnID, runID: AgentRunID) -> Bool {
        guard let current = try? botStore.groupTurn(id: turnID) else { return false }
        return current.state == .running && current.memberRunID == runID
    }

    /// The participant's member thread, created on its first turn: locked to
    /// the bot, execution target from the bot's desktop, and the plan-A guest
    /// marker for a Distill bot on a VM (same rule as a new desk thread).
    private func ensureMemberThread(
        group: BotGroupConversation,
        bot: BotDefinition,
        revision: BotRevision,
        router: AppCommandRouter
    ) throws -> (conversation: BotConversation, thread: AgentThread) {
        guard let participant = try botStore.listGroupParticipants(groupID: group.id)
                .first(where: { $0.botID == bot.id }),
              var conversation = try botStore.conversation(id: participant.memberConversationID),
              conversation.groupID == group.id else {
            throw BotStoreError.invalidInput("\(bot.name) is not in this group.")
        }
        if let linked = conversation.linkedAgentThreadID, let thread = try threadRepo.get(id: linked) {
            let updated = try threadRepo.reconcileBotExecutionTarget(thread)
            if updated.executionTarget != thread.executionTarget {
                router.publishAgentThreadUpdated(updated)
            }
            return (conversation, updated)
        }
        // Same default as a new desk conversation: an empty Distill model
        // resolves to the last-used, then the first listed model.
        // Known gap (T3): the default permission mode asks before tool
        // actions, and this hidden thread has no surface for the approval
        // yet; the turn waits until Stop. T4/T5 project it to the room.
        var routing = BotDeskRouting()
        let snapshots = router.cachedProviderSnapshotsForSend()
        routing.model = BotsViewModel.resolvedUnlinkedDeskModel(
            routing,
            snapshot: snapshots.first { $0.id == routing.providerInstanceID }
                ?? snapshots.first { $0.provider == routing.provider },
            lastUsed: AgentLastModelStore.shared.model(for: routing.provider)
        )
        let model = routing.resolvedModel(defaultModel: BotsViewModel.defaultModel(for:))
        var thread = try router.createAgentThread(
            workspace: nil,
            title: group.title,
            provider: routing.provider,
            model: model,
            permissionMode: routing.permissionMode,
            reasoningEffort: routing.reasoningEffort,
            serviceTier: routing.serviceTier,
            modelSelection: routing.modelSelection,
            providerInstanceId: routing.providerInstanceID,
            runAsUser: routing.runAsUser,
            surfaceID: nil,
            routingConfiguration: nil,
            quiet: true
        )
        let target = BotExecutionDefault.target(for: revision)
        if target == .vm, routing.provider == .distill, routing.runAsUser.uid == getuid() {
            // Marker first: on its own (no `.vm` target yet) it routes nothing.
            try threadRepo.setGuestRuntime(id: thread.id, BotGuestRuntime.distillV1)
        }
        let lockedAt = Date()
        try threadRepo.setActor(id: thread.id, actor: .bot(bot.id), lockedAt: lockedAt, executionTarget: target)
        thread.actor = .bot(bot.id)
        thread.actorLockedAt = lockedAt
        thread.executionTarget = target
        conversation.linkedAgentThreadID = thread.id
        try botStore.upsertConversation(conversation)
        return (conversation, thread)
    }

    // MARK: - Settle

    nonisolated func runCoordinator(
        _ coordinator: AgentRunCoordinator,
        didReceive event: AssistantEvent,
        run: AgentRunID,
        threadId: AgentThreadID
    ) {}

    nonisolated func runCoordinator(
        _ coordinator: AgentRunCoordinator,
        didFinish runId: AgentRunID,
        threadId: AgentThreadID,
        status: AgentRunStatus,
        finalMessage: String?,
        providerThreadId: String?
    ) {
        Task { @MainActor [weak self] in
            self?.settle(runID: runId, threadID: threadId, status: status, finalMessage: finalMessage)
        }
    }

    nonisolated func runCoordinator(
        _ coordinator: AgentRunCoordinator,
        didChangeStatus status: AgentRunStatus,
        runId: AgentRunID,
        threadId: AgentThreadID
    ) {}

    /// Settles the turn that owns `runID`. A finish of any other run (an older
    /// run, a retried turn's previous run) matches nothing and changes nothing.
    /// The turn is found by its run alone (unique, compare-and-set guarded):
    /// a bot deleted mid-turn has no member conversation any more.
    func settle(runID: AgentRunID, threadID: AgentThreadID, status: AgentRunStatus, finalMessage: String?) {
        let seenThrough = seenThroughOnCompletion.removeValue(forKey: runID)
        guard ownedRunIDs.remove(runID) != nil,
              let turn = (try? botStore.listGroupTurns(groupID: nil, states: [.running]))?
                .first(where: { $0.memberRunID == runID }),
              let group = try? botStore.group(id: turn.groupID) else { return }
        let roomThreadID = group.roomThreadID
        defer { schedulePump(group.id) }

        let reply = status == .completed ? replyText(threadID: threadID, runID: runID, finalMessage: finalMessage) : nil
        guard let reply else {
            let state: BotGroupTurn.State = status == .cancelled ? .cancelled
                : status == .interrupted ? .interrupted : .failed
            let error = state == .cancelled ? nil
                : ((try? runRepo.errorMessage(of: runID)) ?? nil)
                    ?? (status == .completed ? "The bot finished without a reply." : "The bot's run ended with \(status.rawValue).")
            move(
                turn,
                from: [.running],
                to: state,
                expectedMemberRunID: runID,
                error: error,
                roomThreadID: roomThreadID,
                outcome: state == .cancelled ? .note(Self.stoppedNote) : .needsAttention
            )
            return
        }
        let isSilent = reply.trimmingCharacters(in: .whitespacesAndNewlines) == BotGroupPromptComposer.silentTurnMarker
        guard let completed = move(
            turn,
            from: [.running],
            to: .completed,
            expectedMemberRunID: runID,
            roomThreadID: roomThreadID,
            outcome: isSilent ? .silent : .reply(reply)
        ) else { return }
        if let seenThrough {
            try? botStore.setGroupParticipantWatermark(
                groupID: group.id, botID: completed.botID, messageID: seenThrough.id, createdAt: seenThrough.createdAt
            )
        }
        if !isSilent { planHandOff(after: completed, reply: reply, group: group) }
    }

    /// A reply that @mentions participants hands them the floor (next hops).
    private func planHandOff(after author: BotGroupTurn, reply: String, group: BotGroupConversation) {
        guard let turns = try? botStore.listGroupTurns(groupID: group.id),
              let latest = turns.max(by: { $0.ordinal < $1.ordinal }),
              let participants = try? activeParticipantBots(groupID: group.id) else { return }
        let plan = BotGroupTurnPlanner.planHandOff(
            replyText: reply,
            author: author,
            groupTurns: turns,
            latestRoundID: latest.roundID,
            participants: participants,
            maxAutoHops: group.maxAutoHops
        )
        let now = Date()
        var ordinal = latest.ordinal + 1
        let handOffs = plan.turns.map { planned -> BotGroupTurn in
            defer { ordinal += 1 }
            return BotGroupTurn(
                groupID: group.id,
                roundID: author.roundID,
                triggerMessageID: author.roomMessageID,
                botID: planned.botID,
                ordinal: ordinal,
                hop: planned.hop,
                createdAt: now,
                updatedAt: now
            )
        }
        let botsByID = Dictionary(participants.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if !handOffs.isEmpty {
            let rows = waitingRows(for: handOffs, roomThreadID: group.roomThreadID, bots: botsByID, after: now)
            do {
                try botStore.insertGroupTurns(handOffs) {
                    for row in rows { try self.messageRepo.append(row) }
                }
                rows.forEach(publishRow)
                handOffs.forEach { publishTurn($0, roomThreadID: group.roomThreadID) }
            } catch {
                botGroupLog.error("bot.group.handoff_failed group=\(group.id.value.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        if !plan.pausedBotIDs.isEmpty {
            let paused = plan.pausedBotIDs.compactMap { botsByID[$0] }
            try? writeRoomRow(AgentMessage(
                threadId: group.roomThreadID,
                role: .system,
                content: BotGroupTurnPlanner.pausedNote(pausedBots: paused, maxAutoHops: group.maxAutoHops),
                createdAt: now.addingTimeInterval(Double(handOffs.count + 1) / 1000)
            ))
        }
    }

    private func replyText(threadID: AgentThreadID, runID: AgentRunID, finalMessage: String?) -> String? {
        // Summaries only: the snapshot/diff blobs are never needed here.
        let stored = (try? checkpointRepo.listSummaries(threadId: threadID))?
            .last(where: { $0.runId == runID })?
            .assistantMessageId
            .flatMap { try? messageRepo.get(id: $0) }
            .flatMap { $0.threadId == threadID && $0.role == .assistant ? $0.content : nil }
        let text = stored ?? finalMessage ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    // MARK: - Room projection

    private enum RowOutcome {
        case reply(String)
        case silent
        case needsAttention
        case note(String)
        case waiting
    }

    static let stoppedNote = "stopped before answering."
    static let supersededNote = "did not answer: a newer message took over."
    static let removedNote = "was removed before answering."
    static let interruptedError = "MacCode closed while this turn was running."

    /// Moves the turn and, with `outcome`, rewrites or removes its room row in
    /// the same transaction, then publishes the row change and turn once each. Nil when
    /// the turn had already moved on, or when the write failed (logged; the
    /// turn keeps its state and its row, and a turn left running is
    /// interrupted with its row at the next launch).
    @discardableResult
    private func move(
        _ turn: BotGroupTurn,
        from expected: [BotGroupTurn.State],
        to state: BotGroupTurn.State,
        expectedMemberRunID: AgentRunID? = nil,
        memberRunID: AgentRunID? = nil,
        clearMemberRunID: Bool = false,
        error: String? = nil,
        clearError: Bool = false,
        roomThreadID: AgentThreadID,
        outcome: RowOutcome? = nil
    ) -> BotGroupTurn? {
        let removesRow: Bool
        if case .silent? = outcome { removesRow = true } else { removesRow = false }
        let row = removesRow ? nil : outcome.map { roomRow(for: turn, roomThreadID: roomThreadID, outcome: $0) }
        let moved: BotGroupTurn?
        do {
            moved = try botStore.transitionGroupTurn(
                id: turn.id,
                from: expected,
                to: state,
                expectedMemberRunID: expectedMemberRunID,
                memberRunID: memberRunID,
                clearMemberRunID: clearMemberRunID,
                error: error,
                clearError: clearError,
                alsoWriting: { _ in
                    if removesRow { try self.messageRepo.delete(ids: [turn.roomMessageID]) }
                    else if let row { try self.messageRepo.append(row) }
                }
            )
        } catch let failure {
            botGroupLog.error("bot.group.turn_move_failed turn=\(turn.id.value.uuidString, privacy: .public) to=\(state.rawValue, privacy: .public) error=\(failure.localizedDescription, privacy: .public)")
            return nil
        }
        guard let moved else { return nil }
        if let row { publishRow(row) }
        if removesRow {
            EventBus.shared.publish(
                kind: .agentMessagesRemoved,
                payload: AppContext.messagesRemovedEventPayload(threadID: roomThreadID, messageIDs: [turn.roomMessageID])
            )
            router?.projectTitioInboxRemoval([turn.roomMessageID], threadID: roomThreadID)
        }
        publishTurn(moved, roomThreadID: roomThreadID)
        return moved
    }

    /// The bot was deleted. The delete already cancelled its unstarted turns
    /// (`cancelledTurnIDs`): their rows settle here. Its running turn stops;
    /// the rest of each group goes on.
    func botWasDeleted(_ botID: BotID, cancelledTurnIDs: [BotGroupTurnID]) {
        settleRemovedBots(cancelledTurnIDs: cancelledTurnIDs) { $0.botID == botID }
    }

    /// Bots left one group (participants edited). Their unstarted turns
    /// there were cancelled by the edit (`cancelledTurnIDs`); their running
    /// turn in that group stops.
    func participantsWereRemoved(groupID: BotGroupID, botIDs: Set<BotID>, cancelledTurnIDs: [BotGroupTurnID]) {
        settleRemovedBots(cancelledTurnIDs: cancelledTurnIDs) {
            $0.groupID == groupID && botIDs.contains($0.botID)
        }
    }

    private func settleRemovedBots(cancelledTurnIDs: [BotGroupTurnID], running isRemoved: (BotGroupTurn) -> Bool) {
        var groups = Set<BotGroupID>()
        for turnID in cancelledTurnIDs {
            guard let turn = try? botStore.groupTurn(id: turnID), turn.state == .cancelled,
                  let group = try? botStore.group(id: turn.groupID) else { continue }
            groups.insert(group.id)
            let row = roomRow(for: turn, roomThreadID: group.roomThreadID, outcome: .note(Self.removedNote))
            do {
                try writeRoomRow(row)
            } catch {
                botGroupLog.error("bot.group.removed_row_failed turn=\(turnID.value.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
            publishTurn(turn, roomThreadID: group.roomThreadID)
        }
        let running = ((try? botStore.listGroupTurns(groupID: nil, states: [.running])) ?? [])
            .filter(isRemoved)
        for turn in running {
            guard let runID = turn.memberRunID,
                  let group = try? botStore.group(id: turn.groupID) else { continue }
            groups.insert(group.id)
            guard move(
                turn,
                from: [.running],
                to: .cancelled,
                expectedMemberRunID: runID,
                roomThreadID: group.roomThreadID,
                outcome: .note(Self.removedNote)
            ) != nil else { continue }
            ownedRunIDs.remove(runID)
            seenThroughOnCompletion.removeValue(forKey: runID)
            coordinator.stopRun(runID)
        }
        groups.forEach(schedulePump)
    }

    /// The turn's settled row: it replaces the waiting row in place (same
    /// id, same position).
    private func roomRow(for turn: BotGroupTurn, roomThreadID: AgentThreadID, outcome: RowOutcome) -> AgentMessage {
        let existing = try? messageRepo.get(id: turn.roomMessageID)
        let identity = identityForRow(turn: turn, existing: existing)
        let content: String
        let role: AgentMessageRole
        switch outcome {
        case .reply(let text):
            content = BotPeerTranscript.encode(peer: identity, text: text)
            role = .assistant
        case .silent:
            preconditionFailure("A silent group turn removes its room row.")
        case .needsAttention:
            content = BotPeerTranscript.encodeActivity(peer: identity, phase: .needsAttention)
            role = .assistant
        case .note(let text):
            content = "\(identity.name) (\(BotPeerTranscript.handleLabel(identity.handle))) \(text)"
            role = .system
        case .waiting:
            content = BotPeerTranscript.encodeActivity(peer: identity, phase: .waiting)
            role = .assistant
        }
        return AgentMessage(
            id: turn.roomMessageID,
            threadId: roomThreadID,
            role: role,
            content: content,
            createdAt: existing?.createdAt ?? turn.createdAt
        )
    }

    /// The bot as the room shows it: the live bot, or the identity the
    /// waiting row captured when the bot has since been deleted.
    private func identityForRow(turn: BotGroupTurn, existing: AgentMessage?) -> BotDefinition {
        if let bot = try? botStore.get(id: turn.botID) { return bot }
        let snapshot = existing.flatMap { BotPeerTranscript.parseActivity($0.content) }
        return BotDefinition(
            id: turn.botID,
            handle: snapshot?.handle ?? "bot",
            name: snapshot?.name ?? "Bot",
            title: snapshot?.title ?? "",
            description: ""
        )
    }

    private func waitingRows(
        for turns: [BotGroupTurn],
        roomThreadID: AgentThreadID,
        bots: [BotID: BotDefinition],
        after date: Date
    ) -> [AgentMessage] {
        turns.enumerated().map { index, turn in
            let bot = bots[turn.botID] ?? identityForRow(turn: turn, existing: nil)
            return AgentMessage(
                id: turn.roomMessageID,
                threadId: roomThreadID,
                role: .assistant,
                content: BotPeerTranscript.encodeActivity(peer: bot, phase: .waiting),
                // Strictly after the trigger so every client orders the rows the same.
                createdAt: date.addingTimeInterval(Double(index + 1) / 1000)
            )
        }
    }

    /// One durable room write, then its event and repaint.
    private func writeRoomRow(_ message: AgentMessage) throws {
        try messageRepo.append(message)
        publishRow(message)
    }

    /// One `agent.message.appended` (with the stored body revision, which a
    /// row replaced in place bumps) and one local repaint for a written row.
    private func publishRow(_ message: AgentMessage) {
        let revision = ((try? messageRepo.bodyRevision(id: message.id)) ?? nil) ?? 1
        EventBus.shared.publish(
            kind: .agentMessageAppended,
            payload: AgentMessageTransport.appendedEventPayload(from: message, bodyRevision: revision)
        )
        router?.projectAgentAppPeerMessage(threadID: message.threadId, messageID: message.id)
    }

    private func publishTurn(_ turn: BotGroupTurn, roomThreadID: AgentThreadID) {
        EventBus.shared.publish(kind: .botGroupTurnUpdated, payload: Self.turnPayload(turn, roomThreadID: roomThreadID))
        onTurnPublished?(turn)
    }

    nonisolated static func turnPayload(_ turn: BotGroupTurn, roomThreadID: AgentThreadID) -> JSONValue {
        func id(_ uuid: UUID) -> JSONValue { .string(uuid.uuidString.lowercased()) }
        return .object([
            "group_id": id(turn.groupID.value),
            "round_id": id(turn.roundID.value),
            "turn_id": id(turn.id.value),
            "bot_id": id(turn.botID.value),
            "state": .string(turn.state.rawValue),
            "ordinal": .number(Double(turn.ordinal)),
            "hop": .number(Double(turn.hop)),
            "room_thread_id": id(roomThreadID.value),
            "room_message_id": id(turn.roomMessageID.value),
            "trigger_message_id": turn.triggerMessageID.map { id($0.value) } ?? .null,
            "run_id": turn.memberRunID.map { id($0.value) } ?? .null,
            "error": turn.error.map(JSONValue.string) ?? .null,
            "updated_at": .number(turn.updatedAt.timeIntervalSince1970),
        ])
    }

    // MARK: - Lookups

    private func activeParticipantBots(groupID: BotGroupID) throws -> [BotDefinition] {
        try botStore.listGroupParticipants(groupID: groupID).compactMap { participant in
            guard let bot = try botStore.get(id: participant.botID), bot.deletedAt == nil else { return nil }
            return bot
        }
    }

    /// A participant's member thread (its provider and locked target).
    func memberThread(id: AgentThreadID) -> AgentThread? {
        (try? threadRepo.get(id: id)) ?? nil
    }

    private func memberThreadID(groupID: BotGroupID, botID: BotID) -> AgentThreadID? {
        guard let participant = (try? botStore.listGroupParticipants(groupID: groupID, includeLeft: true))?
                .first(where: { $0.botID == botID }),
              let conversation = (try? botStore.conversation(id: participant.memberConversationID)) ?? nil else {
            return nil
        }
        return conversation.linkedAgentThreadID
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
