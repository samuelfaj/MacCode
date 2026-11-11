import Foundation
import os
import CoreModel
import Persistence
import SocketServer

private let teamGroupLog = Logger(subsystem: "io.remotecode.agent", category: "bot.group.service")

/// The one entry point for bot teams and group conversations, used by the
/// Mac UI and by the paired-device RPCs alike. Every change publishes
/// `bot.team.updated` or `bot.group.updated` from here (turn changes publish
/// `bot.group.turn.updated` from the orchestrator), so a change made on
/// either side reaches the other.
@MainActor
final class BotTeamGroupService {
    static let readMethods: Set<String> = ["bot.team.list", "bot.group.list", "bot.group.get"]
    static let mutationMethods: Set<String> = [
        "bot.team.create", "bot.team.update", "bot.team.set_members", "bot.team.delete", "bot.team.reorder",
        "bot.group.create", "bot.group.update", "bot.group.set_participants", "bot.group.send",
        "bot.group.stop", "bot.group.retry_turn", "bot.group.select", "bot.group.delete",
    ]

    static func handles(_ method: String) -> Bool {
        readMethods.contains(method) || mutationMethods.contains(method)
    }

    /// Remote calls that create or change teams and groups, or make bots
    /// answer, need the Bots "Control plane" switch on (like `bot.create`,
    /// `bot.save` and `bot.send`). Stop, select and delete stay allowed so a
    /// paired device can still quiet or clean up a group.
    static let controlPlaneMethods: Set<String> = [
        "bot.team.create", "bot.team.update", "bot.team.set_members", "bot.team.reorder",
        "bot.group.create", "bot.group.update", "bot.group.set_participants", "bot.group.send",
        "bot.group.retry_turn",
    ]
    /// Same code and text as `BotRemoteControlAuthority.Error.controlPlaneOff`.
    static let controlPlaneOffCode = -32081

    /// Stable codes for refusals; the message is user-presentable.
    static let notFoundCode = -32044
    static let revisionConflictCode = -32078
    static let defaultTurnsLimit = 50
    static let maxTurnsLimit = 200

    private let botStore: BotStore
    private let orchestrator: BotGroupOrchestrator
    private let isControlPlaneActive: () -> Bool
    /// Last turn change per group, applied to the group's attention state
    /// once per main-actor turn (a send changes several turns at once).
    private var pendingAttention: [BotGroupID: BotGroupTurn] = [:]
    private var attentionFlushScheduled = false
    /// Groups whose delete is in flight: nothing new may start in them.
    private var deletingGroups: Set<BotGroupID> = []
    static let deletingMessage = L("This group is being deleted.")
    /// Groups whose room is on screen on the Mac, one entry per viewer (a
    /// viewer that goes away stops counting). A reply there is already read.
    private final class Viewer {
        weak var owner: AnyObject?
        var groupID: BotGroupID?
        init(owner: AnyObject) { self.owner = owner }
    }
    private var viewers: [Viewer] = []

    init(botStore: BotStore, orchestrator: BotGroupOrchestrator, isControlPlaneActive: @escaping () -> Bool) {
        self.botStore = botStore
        self.orchestrator = orchestrator
        self.isControlPlaneActive = isControlPlaneActive
        orchestrator.onTurnPublished = { [weak self] turn in self?.noteTurnChanged(turn) }
    }

    // MARK: - Teams

    @discardableResult
    func createTeam(
        name: String,
        description: String = "",
        avatarSymbol: String? = nil,
        memberBotIDs: [BotID] = []
    ) throws -> BotTeam {
        let team = try botStore.createTeam(
            name: name,
            description: description,
            avatarSymbol: avatarSymbol ?? "person.3.fill",
            memberBotIDs: memberBotIDs
        )
        publishTeam("created", team: team)
        return team
    }

    /// Nil fields keep their current value.
    @discardableResult
    func updateTeam(
        id: BotTeamID,
        expectedRevision: Int,
        name: String? = nil,
        description: String? = nil,
        avatarSymbol: String? = nil
    ) throws -> BotTeam {
        guard let current = try botStore.team(id: id) else { throw BotStoreError.notFound }
        let team = try botStore.updateTeam(
            id: id,
            expectedRevision: expectedRevision,
            name: name ?? current.name,
            description: description ?? current.description,
            avatarSymbol: avatarSymbol ?? current.avatarSymbol
        )
        publishTeam("updated", team: team)
        return team
    }

    @discardableResult
    func setTeamMembers(id: BotTeamID, expectedRevision: Int, botIDs: [BotID]) throws -> BotTeam {
        let team = try botStore.setTeamMembers(id: id, expectedRevision: expectedRevision, botIDs: botIDs)
        publishTeam("members", team: team)
        return team
    }

    /// Bots and groups stay; groups made from the team lose the link.
    func deleteTeam(id: BotTeamID) throws {
        let linked = try botStore.listGroups(includeHidden: true).filter { $0.teamID == id }.map(\.id)
        try botStore.deleteTeam(id: id)
        EventBus.shared.publish(kind: .botTeamUpdated, payload: .object([
            "change": .string("deleted"),
            "team_id": .string(Self.key(id.value)),
            "revision": .null,
            "deleted": .bool(true),
            "team": .null,
        ]))
        for groupID in linked {
            if let group = try? botStore.group(id: groupID) { publishGroup("updated", group: group) }
        }
    }

    @discardableResult
    func reorderTeams(_ ids: [BotTeamID]) throws -> [BotTeam] {
        try botStore.reorderTeams(ids)
        let teams = try botStore.listTeams()
        EventBus.shared.publish(kind: .botTeamUpdated, payload: .object([
            "change": .string("reordered"),
            "team_ids": .array(teams.map { .string(Self.key($0.id.value)) }),
            "deleted": .bool(false),
        ]))
        return teams
    }

    // MARK: - Groups

    func createGroup(
        title: String,
        teamID: BotTeamID? = nil,
        policy: BotGroupPolicy = .roundtable,
        leadBotID: BotID? = nil,
        maxAutoHops: Int = BotGroupConversation.defaultMaxAutoHops,
        participantBotIDs: [BotID]
    ) async throws -> BotGroupConversation {
        let group = try await orchestrator.createGroup(
            title: title,
            teamID: teamID,
            policy: policy,
            leadBotID: leadBotID,
            maxAutoHops: maxAutoHops,
            participantBotIDs: participantBotIDs
        )
        publishGroup("created", group: group)
        return group
    }

    /// Title, team, policy, lead, hop budget, pin and hide (compare-and-set).
    @discardableResult
    func updateGroup(
        id: BotGroupID,
        expectedRevision: Int,
        _ mutate: (inout BotGroupConversation) -> Void
    ) throws -> BotGroupConversation {
        let group = try botStore.updateGroup(id: id, expectedRevision: expectedRevision) { group in
            mutate(&group)
        }
        publishGroup("updated", group: group)
        return group
    }

    /// Removed bots' unstarted turns are cancelled with a note in the room
    /// and their running turn in this group stops.
    @discardableResult
    func setGroupParticipants(id: BotGroupID, expectedRevision: Int, botIDs: [BotID]) throws -> BotGroupConversation {
        let before = Set(try botStore.listGroupParticipants(groupID: id).map(\.botID))
        let pending = try botStore.listGroupTurns(groupID: id, states: BotGroupTurn.State.pending)
        let group = try botStore.setGroupParticipants(id: id, expectedRevision: expectedRevision, botIDs: botIDs)
        let removed = before.subtracting(botIDs)
        if !removed.isEmpty {
            orchestrator.participantsWereRemoved(
                groupID: id,
                botIDs: removed,
                cancelledTurnIDs: pending.filter { removed.contains($0.botID) }.map(\.id)
            )
        }
        publishGroup("participants", group: group)
        return group
    }

    func send(
        groupID: BotGroupID,
        text: String,
        submitKey: String?,
        attachments: [AgentAttachment] = []
    ) throws -> BotGroupOrchestrator.SendReceipt {
        guard !deletingGroups.contains(groupID) else { throw BotGroupOrchestrator.SendError.rejected(Self.deletingMessage) }
        return try orchestrator.send(groupID: groupID, text: text, submitKey: submitKey, attachments: attachments)
    }

    @discardableResult
    func stop(groupID: BotGroupID) throws -> [BotGroupTurn] {
        guard try botStore.group(id: groupID) != nil else { throw BotStoreError.notFound }
        return orchestrator.stop(groupID: groupID)
    }

    @discardableResult
    func retryTurn(groupID: BotGroupID, turnID: BotGroupTurnID) throws -> BotGroupTurn {
        guard !deletingGroups.contains(groupID) else { throw BotGroupOrchestrator.SendError.rejected(Self.deletingMessage) }
        return try orchestrator.retry(turnID: turnID, groupID: groupID)
    }

    /// The user opened the group: it is read and its attention is cleared
    /// (a group still answering stays `working`). Like attention changes,
    /// this keeps the group's revision so a pending edit still applies.
    @discardableResult
    func select(groupID: BotGroupID) throws -> BotGroupConversation {
        guard let current = try botStore.group(id: groupID) else { throw BotStoreError.notFound }
        let group = try botStore.setGroupAttention(
            id: groupID,
            attentionState: current.attentionState == .working ? .working : .none,
            unread: false
        )
        publishGroup("selected", group: group)
        return group
    }

    /// Deletes the group with its room and private member threads (their
    /// runs stop). Bots and teams stay. The group stops first and its threads
    /// go before its rows: when a run does not stop, the delete fails and the
    /// group stays whole (try again), never leaving unlinked threads behind.
    func deleteGroup(id: BotGroupID) async throws {
        guard let group = try botStore.group(id: id) else { throw BotStoreError.notFound }
        guard !deletingGroups.contains(id) else { throw BotGroupOrchestrator.SendError.rejected(Self.deletingMessage) }
        deletingGroups.insert(id)
        defer { deletingGroups.remove(id) }
        orchestrator.stop(groupID: id)
        let threads = [group.roomThreadID]
            + (try botStore.listGroupMemberConversations(groupID: id)).compactMap(\.linkedAgentThreadID)
        try await deleteThreads(threads)
        let remaining = try botStore.deleteGroup(id: id).filter { !threads.contains($0) }
        pendingAttention.removeValue(forKey: id)
        EventBus.shared.publish(kind: .botGroupUpdated, payload: .object([
            "change": .string("deleted"),
            "group_id": .string(Self.key(id.value)),
            "revision": .null,
            "deleted": .bool(true),
            "group": .null,
        ]))
        // A member thread linked while the first threads were going.
        guard !remaining.isEmpty else { return }
        do {
            try await deleteThreads(remaining)
        } catch {
            teamGroupLog.error("bot.group.delete_threads_failed group=\(id.value.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Test seam for a thread delete that fails; nil deletes through the router.
    var deleteThreadsOverride: (([AgentThreadID]) async throws -> Void)?

    private func deleteThreads(_ threads: [AgentThreadID]) async throws {
        if let deleteThreadsOverride { return try await deleteThreadsOverride(threads) }
        try await orchestrator.router?.deleteAgentThreads(threads)
    }

    /// A deleted bot left its teams and groups (the store did it); the turn
    /// rows settle in the orchestrator, and paired devices re-read the lists.
    func botWasDeleted(_ botID: BotID, cancelledTurnIDs: [BotGroupTurnID]) {
        orchestrator.botWasDeleted(botID, cancelledTurnIDs: cancelledTurnIDs)
        let bot = JSONValue.string(Self.key(botID.value))
        EventBus.shared.publish(kind: .botTeamUpdated, payload: .object([
            "change": .string("bot_deleted"), "bot_id": bot, "deleted": .bool(false),
        ]))
        EventBus.shared.publish(kind: .botGroupUpdated, payload: .object([
            "change": .string("bot_deleted"), "bot_id": bot, "deleted": .bool(false),
        ]))
    }

    // MARK: - Attention

    /// `viewer` shows `groupID`'s room now (nil: no room on screen).
    func setViewing(_ groupID: BotGroupID?, by viewer: AnyObject) {
        viewers.removeAll { $0.owner == nil }
        if let entry = viewers.first(where: { $0.owner === viewer }) {
            entry.groupID = groupID
        } else if groupID != nil {
            let entry = Viewer(owner: viewer)
            entry.groupID = groupID
            viewers.append(entry)
        }
    }

    func isViewing(_ groupID: BotGroupID) -> Bool {
        viewers.contains { $0.owner != nil && $0.groupID == groupID }
    }

    private func noteTurnChanged(_ turn: BotGroupTurn) {
        pendingAttention[turn.groupID] = turn
        guard !attentionFlushScheduled else { return }
        attentionFlushScheduled = true
        // Lifecycle work: never part of the receipt of the RPC that caused it.
        EventBus.outsideMutationCapture {
            Task { @MainActor [weak self] in self?.flushAttention() }
        }
    }

    /// Applies the pending turn changes to their groups' attention state.
    func flushAttention() {
        attentionFlushScheduled = false
        let pending = pendingAttention
        pendingAttention = [:]
        for (groupID, turn) in pending {
            // Only what decides attention: unsettled turns and the changed
            // turn's round, never the group's whole history.
            guard let group = try? botStore.group(id: groupID),
                  let unsettled = try? botStore.listGroupTurns(
                    groupID: groupID, states: BotGroupTurn.State.pending + [.running]
                  ),
                  let round = try? botStore.listGroupTurns(groupID: groupID, roundID: turn.roundID)
            else { continue }
            let turns = round + unsettled
            let next = Self.attention(turns: turns, lastChanged: turn, current: group, viewing: isViewing(groupID))
            guard next.state != group.attentionState || next.unread != group.unread else { continue }
            do {
                let updated = try botStore.setGroupAttention(id: groupID, attentionState: next.state, unread: next.unread)
                publishGroup("attention", group: updated)
            } catch {
                teamGroupLog.error("bot.group.attention_failed group=\(groupID.value.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Working while any turn is unsettled; once all settle, the round of
    /// the last change decides: a failed or interrupted turn needs the user,
    /// a reply is unread activity, a round that was only stopped is quiet.
    /// While the room is on screen (`viewing`) nothing is unread and a reply
    /// needs no dot; a failure still needs the user (like an open Desk).
    nonisolated static func attention(
        turns: [BotGroupTurn],
        lastChanged: BotGroupTurn,
        current: BotGroupConversation,
        viewing: Bool = false
    ) -> (state: BotAttentionState, unread: Bool) {
        let unread = { (value: Bool) in viewing ? false : value }
        if turns.contains(where: { !$0.state.isTerminal }) { return (.working, unread(current.unread)) }
        let round = turns.filter { $0.roundID == lastChanged.roundID }
        if round.contains(where: { $0.state == .failed || $0.state == .interrupted }) { return (.needsAttention, unread(true)) }
        if round.contains(where: { $0.state == .completed }) { return (viewing ? .none : .unreadActivity, unread(true)) }
        return (current.attentionState == .working ? .none : current.attentionState, unread(current.unread))
    }

    // MARK: - Remote (paired devices)

    /// `bot.team.*` / `bot.group.*` RPCs. Refusals throw
    /// `DefiniteMutationRejection` (nothing changed), so the request id is
    /// released instead of fenced as an unknown outcome.
    func dispatchRemote(method: String, params: [String: JSONValue]) async throws -> JSONValue {
        do {
            switch method {
            case "bot.team.list":
                return .object(["teams": .array(try teamRows())])
            case "bot.group.list":
                let groups = try botStore.listGroups(includeHidden: params["include_hidden"]?.boolValue ?? false)
                return .object(["groups": .array(try groups.map(groupRow))])
            case "bot.group.get":
                let id = try Self.requiredUUID(params, "group_id")
                guard let group = try botStore.group(id: BotGroupID(id)) else { throw BotStoreError.notFound }
                let limit = min(max(params["turns_limit"]?.intValue ?? Self.defaultTurnsLimit, 1), Self.maxTurnsLimit)
                let turns = try botStore.listGroupTurns(groupID: group.id).suffix(limit)
                return .object([
                    "group": try groupRow(group),
                    "turns": .array(turns.map { Self.turnRow($0, roomThreadID: group.roomThreadID) }),
                ])
            default:
                if Self.controlPlaneMethods.contains(method), !isControlPlaneActive() {
                    throw DefiniteMutationRejection(JSONRPCError(
                        code: Self.controlPlaneOffCode,
                        message: L("Bot control plane is off.")
                    ))
                }
                return Self.receipt(params, readback: try await mutate(method: method, params: params))
            }
        } catch {
            throw Self.remoteError(error)
        }
    }

    private func mutate(method: String, params: [String: JSONValue]) async throws -> [String: JSONValue] {
        switch method {
        case "bot.team.create":
            let team = try createTeam(
                name: params["name"]?.stringValue ?? "",
                description: params["description"]?.stringValue ?? "",
                avatarSymbol: params["avatar_symbol"]?.stringValue,
                memberBotIDs: try Self.uuidArray(params, "member_bot_ids", required: false).map(BotID.init)
            )
            return ["team": try teamRow(team)]
        case "bot.team.update":
            let team = try updateTeam(
                id: BotTeamID(try Self.requiredUUID(params, "team_id")),
                expectedRevision: try Self.requiredInt(params, "expected_revision"),
                name: params["name"]?.stringValue,
                description: params["description"]?.stringValue,
                avatarSymbol: params["avatar_symbol"]?.stringValue
            )
            return ["team": try teamRow(team)]
        case "bot.team.set_members":
            let team = try setTeamMembers(
                id: BotTeamID(try Self.requiredUUID(params, "team_id")),
                expectedRevision: try Self.requiredInt(params, "expected_revision"),
                botIDs: try Self.uuidArray(params, "bot_ids", required: true).map(BotID.init)
            )
            return ["team": try teamRow(team)]
        case "bot.team.delete":
            let id = try Self.requiredUUID(params, "team_id")
            try deleteTeam(id: BotTeamID(id))
            return ["id": .string(Self.key(id)), "deleted": .bool(true)]
        case "bot.team.reorder":
            let teams = try reorderTeams(try Self.uuidArray(params, "team_ids", required: true).map(BotTeamID.init))
            return ["teams": .array(try teams.map(teamRow))]
        case "bot.group.create":
            let group = try await createGroup(
                title: params["title"]?.stringValue ?? "",
                teamID: try Self.optionalUUID(params, "team_id").map(BotTeamID.init),
                policy: try Self.policy(params) ?? .roundtable,
                leadBotID: try Self.optionalUUID(params, "lead_bot_id").map(BotID.init),
                maxAutoHops: try Self.optionalInt(params, "max_auto_hops") ?? BotGroupConversation.defaultMaxAutoHops,
                participantBotIDs: try Self.uuidArray(params, "participant_bot_ids", required: true).map(BotID.init)
            )
            return ["group": try groupRow(group)]
        case "bot.group.update":
            let teamID = try Self.optionalUUID(params, "team_id").map(BotTeamID.init)
            let leadBotID = try Self.optionalUUID(params, "lead_bot_id").map(BotID.init)
            let policy = try Self.policy(params)
            let maxAutoHops = try Self.optionalInt(params, "max_auto_hops")
            let group = try updateGroup(
                id: BotGroupID(try Self.requiredUUID(params, "group_id")),
                expectedRevision: try Self.requiredInt(params, "expected_revision")
            ) { group in
                if let title = params["title"]?.stringValue { group.title = title }
                if let teamID { group.teamID = teamID }
                if params["clear_team_id"]?.boolValue == true { group.teamID = nil }
                if let policy { group.policy = policy }
                if let leadBotID { group.leadBotID = leadBotID }
                if params["clear_lead_bot_id"]?.boolValue == true { group.leadBotID = nil }
                if let maxAutoHops { group.maxAutoHops = maxAutoHops }
                if let pinned = params["pinned"]?.boolValue { group.pinned = pinned }
                if let hidden = params["hidden"]?.boolValue { group.hidden = hidden }
            }
            return ["group": try groupRow(group)]
        case "bot.group.set_participants":
            let group = try setGroupParticipants(
                id: BotGroupID(try Self.requiredUUID(params, "group_id")),
                expectedRevision: try Self.requiredInt(params, "expected_revision"),
                botIDs: try Self.uuidArray(params, "bot_ids", required: true).map(BotID.init)
            )
            return ["group": try groupRow(group)]
        case "bot.group.send":
            let groupID = BotGroupID(try Self.requiredUUID(params, "group_id"))
            guard let submitKey = params["submit_key"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !submitKey.isEmpty else { throw JSONRPCError.invalidParams }
            if let attachmentIDs = params["attachment_ids"]?.arrayValue, !attachmentIDs.isEmpty {
                throw BotGroupOrchestrator.SendError.attachmentsUnsupported
            }
            let receipt = try send(groupID: groupID, text: params["text"]?.stringValue ?? "", submitKey: submitKey)
            return [
                "group_id": .string(Self.key(receipt.groupID.value)),
                "round_id": .string(Self.key(receipt.roundID.value)),
                "room_thread_id": .string(Self.key(receipt.roomThreadID.value)),
                "user_message_id": .string(Self.key(receipt.userMessageID.value)),
                "submit_key": .string(submitKey),
                "turns": .array(receipt.turns.map { Self.turnRow($0, roomThreadID: receipt.roomThreadID) }),
            ]
        case "bot.group.stop":
            let groupID = BotGroupID(try Self.requiredUUID(params, "group_id"))
            let stopped = try stop(groupID: groupID)
            let room = try botStore.group(id: groupID)?.roomThreadID
            return [
                "group_id": .string(Self.key(groupID.value)),
                "turns": .array(room.map { room in stopped.map { Self.turnRow($0, roomThreadID: room) } } ?? []),
            ]
        case "bot.group.retry_turn":
            let groupID = BotGroupID(try Self.requiredUUID(params, "group_id"))
            let turn = try retryTurn(groupID: groupID, turnID: BotGroupTurnID(try Self.requiredUUID(params, "turn_id")))
            guard let group = try botStore.group(id: groupID) else { throw BotStoreError.notFound }
            return ["turn": Self.turnRow(turn, roomThreadID: group.roomThreadID)]
        case "bot.group.select":
            let group = try select(groupID: BotGroupID(try Self.requiredUUID(params, "group_id")))
            return ["group": try groupRow(group)]
        case "bot.group.delete":
            let id = try Self.requiredUUID(params, "group_id")
            try await deleteGroup(id: BotGroupID(id))
            return ["id": .string(Self.key(id)), "deleted": .bool(true)]
        default:
            throw JSONRPCError.methodNotFound
        }
    }

    // MARK: - Wire rows

    func teamRows() throws -> [JSONValue] {
        let members = Dictionary(grouping: try botStore.listTeamMembers(), by: \.teamID)
        return try botStore.listTeams().map { teamRow($0, members: members[$0.id] ?? []) }
    }

    private func teamRow(_ team: BotTeam) throws -> JSONValue {
        teamRow(team, members: try botStore.listTeamMembers(teamID: team.id))
    }

    private func teamRow(_ team: BotTeam, members: [BotTeamMember]) -> JSONValue {
        .object([
            "id": .string(Self.key(team.id.value)),
            "name": .string(team.name),
            "description": .string(team.description),
            "avatar_symbol": .string(team.avatarSymbol),
            "sort_order": .number(Double(team.sortOrder)),
            "revision": .number(Double(team.revision)),
            "member_bot_ids": .array(members.map { .string(Self.key($0.botID.value)) }),
            "created_at": .number(team.createdAt.timeIntervalSince1970),
            "updated_at": .number(team.updatedAt.timeIntervalSince1970),
        ])
    }

    func groupRow(_ group: BotGroupConversation) throws -> JSONValue {
        let participants = try botStore.listGroupParticipants(groupID: group.id, includeLeft: true)
        let threads = Dictionary(
            try botStore.listGroupMemberConversations(groupID: group.id).map { ($0.id, $0.linkedAgentThreadID) },
            uniquingKeysWith: { first, _ in first }
        )
        let ordered = participants.filter(\.isActive) + participants.filter { !$0.isActive }
        func id(_ uuid: UUID?) -> JSONValue { uuid.map { .string(Self.key($0)) } ?? .null }
        /// The member thread's provider and locked target (the Mac inspector's
        /// route chip); null before the first turn or the target lock.
        func route(_ threadID: AgentThreadID?) -> (provider: JSONValue, target: JSONValue) {
            guard let threadID, let thread = orchestrator.memberThread(id: threadID) else { return (.null, .null) }
            let target = thread.actorLockedAt == nil ? nil : thread.executionTarget
            return (.string(thread.provider.rawValue), target.map { .string($0.rawValue) } ?? .null)
        }
        return .object([
            "id": .string(Self.key(group.id.value)),
            "title": .string(group.title),
            "team_id": id(group.teamID?.value),
            "room_thread_id": .string(Self.key(group.roomThreadID.value)),
            "policy": .string(group.policy.rawValue),
            "lead_bot_id": id(group.leadBotID?.value),
            "max_auto_hops": .number(Double(group.maxAutoHops)),
            "pinned": .bool(group.pinned),
            "hidden": .bool(group.hidden),
            "unread": .bool(group.unread),
            "attention_state": .string(Self.wireAttention(group.attentionState)),
            "revision": .number(Double(group.revision)),
            "participants": .array(ordered.map { participant in
                let threadID = threads[participant.memberConversationID] ?? nil
                let route = route(threadID)
                return .object([
                    "bot_id": .string(Self.key(participant.botID.value)),
                    "member_conversation_id": .string(Self.key(participant.memberConversationID.value)),
                    "member_thread_id": id(threadID?.value),
                    "provider": route.provider,
                    "execution_target": route.target,
                    "sort_order": .number(Double(participant.sortOrder)),
                    "joined_at": .number(participant.joinedAt.timeIntervalSince1970),
                    "left_at": participant.leftAt.map { .number($0.timeIntervalSince1970) } ?? .null,
                ])
            }),
            "created_at": .number(group.createdAt.timeIntervalSince1970),
            "updated_at": .number(group.updatedAt.timeIntervalSince1970),
        ])
    }

    nonisolated static func turnRow(_ turn: BotGroupTurn, roomThreadID: AgentThreadID) -> JSONValue {
        BotGroupOrchestrator.turnPayload(turn, roomThreadID: roomThreadID)
    }

    nonisolated static func wireAttention(_ state: BotAttentionState) -> String {
        switch state {
        case .none: return "none"
        case .working: return "working"
        case .unreadActivity: return "unread_activity"
        case .needsAttention: return "needs_attention"
        }
    }

    // MARK: - Events

    private func publishTeam(_ change: String, team: BotTeam) {
        let row = (try? teamRow(team)) ?? .null
        EventBus.shared.publish(kind: .botTeamUpdated, payload: .object([
            "change": .string(change),
            "team_id": .string(Self.key(team.id.value)),
            "revision": .number(Double(team.revision)),
            "deleted": .bool(false),
            "team": row,
        ]))
    }

    private func publishGroup(_ change: String, group: BotGroupConversation) {
        let row = (try? groupRow(group)) ?? .null
        EventBus.shared.publish(kind: .botGroupUpdated, payload: .object([
            "change": .string(change),
            "group_id": .string(Self.key(group.id.value)),
            "revision": .number(Double(group.revision)),
            "deleted": .bool(false),
            "group": row,
        ]))
    }

    // MARK: - Params and errors

    private nonisolated static func key(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }

    private nonisolated static func requiredUUID(_ params: [String: JSONValue], _ key: String) throws -> UUID {
        guard let uuid = params[key]?.stringValue.flatMap(UUID.init(uuidString:)) else { throw JSONRPCError.invalidParams }
        return uuid
    }

    private nonisolated static func optionalUUID(_ params: [String: JSONValue], _ key: String) throws -> UUID? {
        guard let value = params[key], value != .null else { return nil }
        guard let uuid = value.stringValue.flatMap(UUID.init(uuidString:)) else { throw JSONRPCError.invalidParams }
        return uuid
    }

    private nonisolated static func requiredInt(_ params: [String: JSONValue], _ key: String) throws -> Int {
        guard let value = params[key]?.intValue else { throw JSONRPCError.invalidParams }
        return value
    }

    private nonisolated static func optionalInt(_ params: [String: JSONValue], _ key: String) throws -> Int? {
        guard let value = params[key], value != .null else { return nil }
        guard let int = value.intValue else { throw JSONRPCError.invalidParams }
        return int
    }

    private nonisolated static func uuidArray(
        _ params: [String: JSONValue],
        _ key: String,
        required: Bool
    ) throws -> [UUID] {
        guard let value = params[key], value != .null else {
            if required { throw JSONRPCError.invalidParams }
            return []
        }
        guard let array = value.arrayValue else { throw JSONRPCError.invalidParams }
        return try array.map { item in
            guard let uuid = item.stringValue.flatMap(UUID.init(uuidString:)) else { throw JSONRPCError.invalidParams }
            return uuid
        }
    }

    private nonisolated static func policy(_ params: [String: JSONValue]) throws -> BotGroupPolicy? {
        guard let value = params["policy"], value != .null else { return nil }
        guard let policy = value.stringValue.flatMap(BotGroupPolicy.init(rawValue:)) else {
            throw JSONRPCError(code: -32602, message: "Policy must be roundtable, lead or mentions_only.")
        }
        return policy
    }

    private nonisolated static func receipt(_ params: [String: JSONValue], readback: [String: JSONValue]) -> JSONValue {
        let requestID = params["client_request_id"]?.stringValue ?? UUID().uuidString.lowercased()
        var body: [String: JSONValue] = [
            "request_id": .string(requestID),
            "client_request_id": .string(requestID),
            "receipt_id": .string(UUID().uuidString.lowercased()),
            "status": .string("completed"),
            "readback": .object(readback),
        ]
        if let hostID = params["host_id"] { body["host_id"] = hostID }
        return .object(body)
    }

    /// Refusals that happen before any write become definite rejections with
    /// a stable code; anything else keeps its own mapping.
    nonisolated static func remoteError(_ error: Error) -> Error {
        func rejected(_ code: Int, _ message: String, kind: String) -> Error {
            DefiniteMutationRejection(JSONRPCError(
                code: code,
                message: message,
                data: .object(["domain": .string("bot_group"), "kind": .string(kind)])
            ))
        }
        switch error {
        case let rejection as DefiniteMutationRejection:
            return rejection
        case let error as JSONRPCError:
            return DefiniteMutationRejection(error)
        case let error as BotStoreError:
            switch error {
            case .notFound: return rejected(notFoundCode, L("That team, group or bot no longer exists."), kind: "not_found")
            case .revisionConflict: return rejected(revisionConflictCode, error.description, kind: "revision_conflict")
            case .invalidInput(let message): return rejected(-32602, message, kind: "invalid_input")
            case .invalidRow: return error
            }
        case let error as BotGroupOrchestrator.SendError:
            return rejected(-32602, error.errorDescription ?? L("The message was refused."), kind: "send_refused")
        default:
            return error
        }
    }
}
