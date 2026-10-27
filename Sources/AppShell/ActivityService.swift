import Foundation
import CoreModel
import Persistence
import RemoteCodeTreaty
import SocketServer

typealias ActivityCounts = AgentActivityCounts
typealias ActivityPage = AgentActivityPage

final class ActivityService: @unchecked Sendable {
    private let db: SQLiteDB
    private let readDB: SQLiteDB
    private let workspaceNames: [WorkspaceID: String]
    /// Valid `TabColor` raw values only; a workspace without a known color has no entry.
    private let workspaceColors: [WorkspaceID: String]
    private let activeRunIDProvider: (AgentThreadID) -> AgentRunID?
    private let registeredScripts: [AgentActivityItem]
    /// Live terminal and SSH tabs with a busy foreground job; never persisted.
    private let busySurfaces: [AgentActivityItem]

    @MainActor
    init(context: AppContext, activeRunIDProvider: ((AgentThreadID) -> AgentRunID?)? = nil) {
        db = context.db
        readDB = context.readDB
        let colors = context.state.workspaces.compactMapValues { TabColor.from($0.metadata["color"])?.rawValue }
        workspaceNames = context.state.workspaces.mapValues(\.name)
        workspaceColors = colors
        let activeRuns = Dictionary(uniqueKeysWithValues: context.coordinator.primaryActiveThreadIdsSnapshot().compactMap { thread in
            context.coordinator.activeRunId(threadId: thread).map { (thread, $0) }
        })
        self.activeRunIDProvider = activeRunIDProvider ?? { activeRuns[$0] }
        registeredScripts = context.projectScriptRuns.activeSnapshot().map { script in
            AgentActivityItem(
                id: "project-script:\(script.surfaceID.value.uuidString):\(script.startedAt.timeIntervalSince1970)",
                kind: .notification, workspaceID: script.workspaceID.value, surfaceID: script.surfaceID.value,
                state: .running, title: "Project script: \(PetAttentionRedactor.safeContextLabel(script.name) ?? "Running")",
                workspaceName: context.state.workspaces[script.workspaceID]?.name, workspaceColor: colors[script.workspaceID], occurredAt: script.startedAt, startedAt: script.startedAt
            )
        }
        busySurfaces = Self.busySurfaceItems(
            ActiveSurfaceProjector.currentItems(context: context),
            excluding: Set(registeredScripts.compactMap(\.surfaceID)),
            now: Date(),
            workspaceColors: colors
        )
    }

    /// Database-only seam for parity tests and benches over a copy of real data.
    init(db: SQLiteDB, readDB: SQLiteDB, activeRunIDProvider: @escaping (AgentThreadID) -> AgentRunID? = { _ in nil }) {
        self.db = db
        self.readDB = readDB
        workspaceNames = [:]
        workspaceColors = [:]
        self.activeRunIDProvider = activeRunIDProvider
        registeredScripts = []
        busySurfaces = []
    }

    /// Busy terminal and SSH tabs count as running work. Project-script tabs already
    /// have their own row, and browser/diff loading is not user work.
    static func busySurfaceItems(_ surfaces: [ActiveSurfaceItem], excluding scriptSurfaceIDs: Set<UUID>, now: Date, workspaceColors: [WorkspaceID: String] = [:]) -> [AgentActivityItem] {
        surfaces
            .filter { ($0.type == .terminal || $0.type == .ssh) && !scriptSurfaceIDs.contains($0.surfaceID.value) }
            .map { surface in
                let label = surface.type == .ssh ? "SSH" : "Terminal"
                return AgentActivityItem(
                    id: "surface:\(surface.surfaceID.value.uuidString)", kind: .operation,
                    workspaceID: surface.workspaceID.value, surfaceID: surface.surfaceID.value, state: .running,
                    title: PetAttentionRedactor.safeContextLabel(surface.title) ?? label,
                    workspaceName: surface.workspaceName, workspaceColor: workspaceColors[surface.workspaceID], occurredAt: now, originLabel: label
                )
            }
    }

    func list(_ params: [String: JSONValue]) throws -> JSONValue {
        let filter = try ActivityFilter(params: params)
        let snapshotAt = filter.cursor.flatMap(ActivityCursor.init(rawValue:))?.snapshotAt ?? Date()
        let cursor = filter.cursor.flatMap(ActivityCursor.init(rawValue:))
        guard filter.cursor == nil || cursor != nil else { throw JSONRPCError.invalidParams }

        var items = try projectedItems(filter: filter, snapshotAt: snapshotAt, includeDisplayDetail: true)
        items.sort(by: Self.activityOrder)
        let counts = Self.counts(for: items)
        let byWorkspace = Self.workspaceCounts(for: items)
        let selected: [AgentActivityItem]
        switch filter.section {
        case "running": selected = items.filter { $0.state == .queued || ($0.state == .running && !$0.blocking) }
        case "needs_you": selected = items.filter(\.needsAction)
        case "finished": selected = items.filter { Self.isTerminal($0.state) }
        case "just_finished": selected = items.filter(Self.isJustFinished)
        default: selected = items
        }
        let page = selected.filter { item in
            guard let cursor else { return true }
            return item.occurredAt < cursor.occurredAt || (item.occurredAt == cursor.occurredAt && item.id > cursor.id)
        }
        let limited = Array(page.prefix(filter.limit))
        let next = page.count > filter.limit
            ? limited.last.map { ActivityCursor(occurredAt: $0.occurredAt, id: $0.id, snapshotAt: snapshotAt).rawValue }
            : nil
        return try Self.json(AgentActivityPage(items: limited, nextCursor: next, counts: counts, generatedAt: snapshotAt, workspaceCounts: byWorkspace))
    }

    /// The same `counts` and `workspaceCounts` an unfiltered `list` returns, for the Pet and
    /// sidebar indicators. It builds the identical items so the numbers cannot drift from the
    /// Activity window, but skips what only a page shows: checkpoint files, redacted
    /// notification summaries, the sort and the JSON encoding.
    func counts() throws -> (global: AgentActivityCounts, byWorkspace: [String: AgentActivityCounts]) {
        let items = try projectedItems(filter: ActivityFilter(params: [:]), snapshotAt: Date(), includeDisplayDetail: false)
        let byWorkspace = Self.workspaceCounts(for: items)
        ActivityChangeEmitter.shared.observe(items: items, byWorkspace: byWorkspace)
        return (Self.counts(for: items), byWorkspace)
    }

    /// Feeds the unfiltered rows to `agent.activity.changed` after a mutation.
    func observeChanges() throws {
        _ = try counts()
    }

    private func projectedItems(filter: ActivityFilter, snapshotAt: Date, includeDisplayDetail: Bool) throws -> [AgentActivityItem] {
        let threads = try AgentThreadRepository(db: readDB).list().filter { !$0.isEphemeral && !AgentThreadTitle.isSubagentThreadTitle($0.title) }
        let threadByID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id.description, $0) })
        let runs = try allRuns(threadByID: threadByID)
        let origins = try ActivityOriginProjection.load(db: readDB, threads: threads)
        let runByID = Dictionary(uniqueKeysWithValues: runs.map { ($0.runID.description, $0) })
        let allCallbacks = try ProviderPendingCallbackRepository(db: readDB).list(states: [.pending, .stale, .approved, .declined, .cancelled, .resolved, .acknowledged])
        let callbacks = allCallbacks.filter { $0.state == .pending || $0.state == .stale }
        let activeRunByThread = Dictionary(uniqueKeysWithValues: threads.compactMap { thread in
            activeRunIDProvider(thread.id).map { (thread.id.description, $0) }
        })
        func callbackRun(_ callback: ProviderPendingCallback) -> AgentRunID? {
            guard callback.state == .pending,
                  let active = activeRunByThread[callback.threadId.description],
                  let run = runByID[active.description], run.status == "running",
                  callback.createdAt >= run.startedAt else { return nil }
            return active
        }
        let blockedRunIDs = Set(callbacks.compactMap(callbackRun))
        let resultRepository = AgentRunResultRepository(db: readDB)
        let resultRows = try stride(from: 0, to: runs.count, by: 500).flatMap { start in
            try resultRepository.list(runIds: Array(runs[start..<min(start + 500, runs.count)].map(\.runID)))
        }
        let resultByRun = Dictionary(uniqueKeysWithValues: resultRows.map { ($0.runId.description, $0) })
        let checkpointByRun = includeDisplayDetail ? try checkpointEvidence(runIDs: runs.map(\.runID)) : [:]
        let notificationStates = try loadNotificationStates(db: readDB)
        // Activity is an inbox, not a run log: a conversation shows its latest result, and a
        // failure the conversation already moved past (a later run) no longer needs the user.
        var latestRunByThread = [String: AgentRunID]()
        var latestResultByThread = [String: AgentRunID]()
        // Only runs the snapshot can see compete, so a page cursor stays stable while new runs land.
        for row in runs where (row.finishedAt ?? row.startedAt) <= snapshotAt {
            let key = row.threadID.description
            if latestRunByThread[key] == nil { latestRunByThread[key] = row.runID }
            if latestResultByThread[key] == nil, Self.terminalRunStatuses.contains(row.status) { latestResultByThread[key] = row.runID }
        }

        var items = runs.compactMap { row -> AgentActivityItem? in
            guard let thread = threadByID[row.threadID.description] else { return nil }
            if Self.terminalRunStatuses.contains(row.status), latestResultByThread[row.threadID.description] != row.runID { return nil }
            let superseded = latestRunByThread[row.threadID.description] != row.runID
            let result = resultByRun[row.runID.description]
            let state: AgentActivityState
            switch row.status {
            case "pending": state = .queued
            case "running": state = activeRunByThread[row.threadID.description] == row.runID ? .running : .needsYou
            case "completed": state = .completed
            case "failed": state = .failed
            case "interrupted": state = .interrupted
            case "cancelled": state = row.terminalReason == "userStop" ? .stopped : .interrupted
            default: return nil
            }
            let terminal = Self.isTerminal(state)
            // Clear all reaches a run left "running" with no live process too.
            let orphanAcknowledgedAt = state == .needsYou ? notificationStates[Self.orphanRunLedgerKey(row.runID)]?.acknowledgedAt : nil
            let needsAction = !superseded && ((state == .needsYou && orphanAcknowledgedAt == nil)
                || ((state == .failed || state == .interrupted) && result?.attentionAcknowledgedAt == nil
                    && !origins.resolvedBotFailureRunIDs.contains(row.runID.description)))
            let checkpoint = checkpointByRun[row.runID.description]
            let workspaceName = thread.workspaceId.flatMap { workspaceNames[$0] }
            let botLink = origins.botLinksByThreadID[thread.id.value.uuidString.lowercased()]
            return AgentActivityItem(
                id: "run:\(row.runID.description)", kind: .agent, runID: row.runID.value,
                workspaceID: thread.workspaceId?.value, threadID: thread.id.value, state: state,
                title: thread.title, workspaceName: workspaceName, workspaceColor: thread.workspaceId.flatMap { workspaceColors[$0] }, provider: thread.provider.rawValue,
                summary: result?.summary ?? (state == .needsYou
                    ? "This run has no active process. Send a new message to resume, or dismiss this alert."
                    : (terminal ? "No summary available for this run" : nil)),
                occurredAt: row.finishedAt ?? row.startedAt, startedAt: row.startedAt, finishedAt: row.finishedAt,
                viewedAt: result?.viewedAt, attentionAcknowledgedAt: result?.attentionAcknowledgedAt ?? orphanAcknowledgedAt,
                needsAction: needsAction, blocking: blockedRunIDs.contains(row.runID), finalMessageID: result?.finalMessageId?.value,
                checkpointTurnCount: checkpoint?.turnCount, changedFiles: checkpoint?.files ?? [], error: row.error,
                botID: botLink?.botID, conversationID: botLink?.conversationID,
                originLabel: origins.labelsByRunID[row.runID.description]
            )
        }

        for callback in callbacks {
            guard let thread = threadByID[callback.threadId.description] else { continue }
            let activeRun = callbackRun(callback)
            let state: AgentActivityState
            if callback.state == .stale || activeRun == nil { state = .expired }
            else { state = callback.kind == .approval ? .waitingApproval : .waitingAnswer }
            let botLink = origins.botLinksByThreadID[thread.id.value.uuidString.lowercased()]
            let requestID = Self.requestItemID(callback, activeRun: activeRun)
            // Keyed by thread + request, so a cleared approval stays cleared when its
            // run ends and the item id switches to the expired form.
            let acknowledgedAt = notificationStates[Self.requestLedgerKey(callback)]?.acknowledgedAt
            items.append(AgentActivityItem(
                id: requestID, kind: .request, runID: activeRun?.value, requestID: callback.requestId,
                workspaceID: thread.workspaceId?.value, threadID: thread.id.value, state: state,
                title: state == .expired ? "Request expired" : (callback.kind == .approval ? "Approve or decline request" : "Reply to question"),
                workspaceName: thread.workspaceId.flatMap { workspaceNames[$0] },
                workspaceColor: thread.workspaceId.flatMap { workspaceColors[$0] },
                provider: thread.provider.rawValue,
                summary: state == .expired ? "This request can no longer be answered. The run is no longer waiting for it."
                    : (callback.kind == .approval ? BotAttentionItemKind.approval.resolutionHint : BotAttentionItemKind.question.resolutionHint),
                occurredAt: callback.createdAt,
                attentionAcknowledgedAt: acknowledgedAt,
                needsAction: state != .expired && acknowledgedAt == nil, blocking: activeRun != nil,
                botID: botLink?.botID, conversationID: botLink?.conversationID
            ))
        }

        let notifications = try NotificationRepository(db: readDB).list(
            workspaceId: filter.workspaceID.map(WorkspaceID.init), limit: Int.max
        )
        let knownRunIDs = Set(runs.map { $0.runID.description })
        let knownRequestIDs = Set(allCallbacks.map { "\($0.threadId.description):\($0.requestId)" })
        let botNotificationMetadata = BotAttentionNotificationMetadataStore(db: readDB).all()
        let canonicalBotAttentionIDs = origins.botAttentionIDs
        for note in notifications {
            let category = note.category.flatMap(PetNotificationCategory.init(rawValue:))
            let payload = Self.notificationPayload(note.body)
            if payload.runID.map(knownRunIDs.contains) == true { continue }
            if let threadID = payload.threadID, let requestID = payload.requestID,
               knownRequestIDs.contains("\(threadID):\(requestID)") { continue }
            let title = category?.presentation.title ?? "Notification"
            let isFailure = category.map(Self.notificationFailureCategories.contains) ?? false
            let state = notificationStates[note.id]
            let botMetadata = botNotificationMetadata[note.id].flatMap { $0.notificationID == note.id ? $0 : nil }
            let canonicalRequestID = botMetadata.map { "bot-attention:\($0.attentionItemID.lowercased())" }
            if let canonicalRequestID, canonicalBotAttentionIDs.contains(canonicalRequestID) { continue }
            // A cleared needs-you notice (file conflict) leaves Needs you and lands in Finished.
            let isResolutionRequired = category?.classification == .needsYou && !isFailure && note.readAt == nil
                && state?.acknowledgedAt == nil
            items.append(AgentActivityItem(
                id: "notification:\(note.id)", kind: .notification, notificationID: note.id, workspaceID: note.workspaceId?.value,
                surfaceID: note.surfaceId?.value, state: isFailure ? .failed : (isResolutionRequired ? .needsYou : .completed), title: title,
                workspaceName: note.workspaceId.flatMap { workspaceNames[$0] },
                workspaceColor: note.workspaceId.flatMap { workspaceColors[$0] },
                summary: category == nil || !includeDisplayDetail ? nil : (Self.notificationSummary(payload.activitySummary) ?? category?.presentation.detail),
                occurredAt: note.createdAt, finishedAt: isResolutionRequired ? nil : note.createdAt,
                viewedAt: state?.viewedAt,
                attentionAcknowledgedAt: state?.acknowledgedAt,
                needsAction: isResolutionRequired || (isFailure && state?.acknowledgedAt == nil), blocking: false,
                botID: (botMetadata?.botID).flatMap(UUID.init(uuidString:))
            ))
        }

        items.append(contentsOf: registeredScripts)
        items.append(contentsOf: busySurfaces)
        items.append(contentsOf: origins.botRequests)
        items.append(contentsOf: origins.scheduledOccurrences)
        return Self.applyingResultsLimit(items.filter { $0.occurredAt <= snapshotAt && filter.matches($0) })
    }

    func setViewed(_ params: [String: JSONValue]) throws -> JSONValue {
        guard let rawIDs = params["item_ids"]?.arrayValue, rawIDs.count <= 200,
              rawIDs.allSatisfy({ $0.stringValue != nil }), let viewed = params["viewed"]?.boolValue else {
            throw JSONRPCError.invalidParams
        }
        let ids = rawIDs.compactMap(\.stringValue)
        guard Set(ids).count == ids.count else { throw JSONRPCError.invalidParams }
        let runIDs = try ids.filter { $0.hasPrefix("run:") }.map { id -> AgentRunID in
            guard let uuid = UUID(uuidString: String(id.dropFirst(4))) else { throw JSONRPCError.invalidParams }
            return AgentRunID(uuid)
        }
        let notificationIDs = ids.filter { $0.hasPrefix("notification:") }.map { String($0.dropFirst("notification:".count)) }
        let scheduledIDs = ids.filter { $0.hasPrefix("scheduled-occurrence:") }.map { String($0.dropFirst("scheduled-occurrence:".count)) }
        guard runIDs.count + notificationIDs.count + scheduledIDs.count == ids.count else { throw JSONRPCError.invalidParams }
        var restoreRuns = [AgentRunID: Date?]()
        var restoreNotifications = [String: Date?]()
        var restoreScheduled = [String: Date?]()
        if let rawRestore = params["restore_viewed_at"] {
            guard let map = rawRestore.objectValue else { throw JSONRPCError.invalidParams }
            for (id, value) in map {
                guard ids.contains(id) else { throw JSONRPCError.invalidParams }
                let date: Date?
                if case .null = value { date = nil }
                else if let text = value.stringValue, let parsed = Self.parseDate(text) { date = parsed }
                else { throw JSONRPCError.invalidParams }
                if id.hasPrefix("run:") {
                    guard let uuid = UUID(uuidString: String(id.dropFirst(4))) else { throw JSONRPCError.invalidParams }
                    restoreRuns.updateValue(date, forKey: AgentRunID(uuid))
                } else if id.hasPrefix("notification:") {
                    restoreNotifications.updateValue(date, forKey: String(id.dropFirst("notification:".count)))
                } else if id.hasPrefix("scheduled-occurrence:") {
                    restoreScheduled.updateValue(date, forKey: String(id.dropFirst("scheduled-occurrence:".count)))
                } else { throw JSONRPCError.invalidParams }
            }
        }
        let operationAt = viewed ? Date() : nil
        let operationTimestamp = operationAt.map(Self.isoFractionalString)
        let changed = try db.performSync { database in
            try database.transaction {
                let runStatus = try database.prepare("SELECT status FROM agent_runs WHERE id = ?;")
                for runID in runIDs {
                    try runStatus.bind(1, runID.description)
                    guard try runStatus.step(), ["completed", "failed", "interrupted", "cancelled"].contains(runStatus.columnText(0) ?? "") else {
                        throw JSONRPCError.invalidParams
                    }
                    runStatus.reset()
                }
                let scheduledExists = try database.prepare("SELECT status FROM scheduled_task_runs WHERE id = ? AND agent_run_id IS NULL;")
                for id in scheduledIDs {
                    try scheduledExists.bind(1, id)
                    guard try scheduledExists.step(), ["completed", "failed", "cancelled"].contains(scheduledExists.columnText(0) ?? "") else { throw JSONRPCError.invalidParams }
                    scheduledExists.reset()
                }
                let notificationExists = try database.prepare("SELECT category FROM notifications WHERE id = ? AND dismissed_at IS NULL;")
                for id in notificationIDs {
                    try notificationExists.bind(1, id)
                    guard try notificationExists.step() else { throw JSONRPCError.invalidParams }
                    notificationExists.reset()
                }
                let ensureResult = try database.prepare("INSERT OR IGNORE INTO agent_run_results(run_id) SELECT id FROM agent_runs WHERE id = ?;")
                for runID in runIDs {
                    try ensureResult.bind(1, runID.description); _ = try ensureResult.step(); ensureResult.reset()
                }
                let stamp = operationTimestamp
                let runUpdate = try database.prepare("UPDATE agent_run_results SET viewed_at = ? WHERE run_id = ?;")
                for runID in runIDs where restoreRuns[runID] == nil {
                    try runUpdate.bind(1, stamp); try runUpdate.bind(2, runID.description); _ = try runUpdate.step(); runUpdate.reset()
                }
                for (runID, date) in restoreRuns {
                    try runUpdate.bind(1, date.map(Self.isoFractionalString)); try runUpdate.bind(2, runID.description)
                    _ = try runUpdate.step(); runUpdate.reset()
                }
                let notificationUpdate = try database.prepare("INSERT INTO activity_notification_state(viewed_at, item_id) VALUES (?, ?) ON CONFLICT(item_id) DO UPDATE SET viewed_at = excluded.viewed_at;")
                for id in notificationIDs where restoreNotifications[id] == nil {
                    try notificationUpdate.bind(1, stamp); try notificationUpdate.bind(2, id); _ = try notificationUpdate.step(); notificationUpdate.reset()
                }
                for (id, date) in restoreNotifications {
                    try notificationUpdate.bind(1, date.map(Self.isoFractionalString)); try notificationUpdate.bind(2, id)
                    _ = try notificationUpdate.step(); notificationUpdate.reset()
                }
                for id in scheduledIDs where restoreScheduled[id] == nil {
                    try notificationUpdate.bind(1, stamp); try notificationUpdate.bind(2, "activity:scheduled-occurrence:\(id)")
                    _ = try notificationUpdate.step(); notificationUpdate.reset()
                }
                for (id, date) in restoreScheduled {
                    try notificationUpdate.bind(1, date.map(Self.isoFractionalString)); try notificationUpdate.bind(2, "activity:scheduled-occurrence:\(id)")
                    _ = try notificationUpdate.step(); notificationUpdate.reset()
                }
                return ids
            }
        }
        return .object(["updated_ids": .array(changed.map(JSONValue.string)), "viewed_at": operationAt.map { .string(Self.isoFractionalString($0)) } ?? .null])
    }

    func acknowledge(_ params: [String: JSONValue]) throws -> JSONValue {
        if let id = params["item_id"]?.stringValue {
            guard try setAcknowledged([id], acknowledged: true) == [id] else { throw JSONRPCError.invalidParams }
            return .object(["acknowledged": .bool(true), "item_id": .string(id)])
        }
        guard let rawIDs = params["item_ids"]?.arrayValue, rawIDs.count <= 200,
              rawIDs.allSatisfy({ $0.stringValue != nil }) else { throw JSONRPCError.invalidParams }
        let ids = rawIDs.compactMap(\.stringValue)
        guard Set(ids).count == ids.count else { throw JSONRPCError.invalidParams }
        let acknowledged = params["acknowledged"]?.boolValue ?? true
        let updated = try setAcknowledged(ids, acknowledged: acknowledged)
        return .object(["acknowledged": .bool(acknowledged), "updated_ids": .array(updated.map(JSONValue.string))])
    }

    /// Returns the ids whose acknowledgment changed, in request order. Items that are no
    /// longer eligible are skipped; ids of a kind that cannot be acknowledged throw.
    /// Every Needs you kind can be cleared (owner, 2026-10-14: Clear all leaves nothing):
    /// a request only leaves the inbox, its thread still holds the live card.
    private func setAcknowledged(_ ids: [String], acknowledged: Bool) throws -> [String] {
        var runIDs = [AgentRunID: String]()
        var botAttentionIDs = [BotAttentionItemID: String]()
        var scheduledIDs = [String]()
        var notificationIDs = [String]()
        var requestIDs = [String]()
        for id in ids {
            if id.hasPrefix("run:"), let uuid = UUID(uuidString: String(id.dropFirst(4))) {
                runIDs[AgentRunID(uuid)] = id
            } else if id.hasPrefix("bot-attention:"), let uuid = UUID(uuidString: String(id.dropFirst("bot-attention:".count))) {
                botAttentionIDs[BotAttentionItemID(uuid)] = id
            } else if id.hasPrefix("scheduled-occurrence:") {
                scheduledIDs.append(String(id.dropFirst("scheduled-occurrence:".count)))
            } else if id.hasPrefix("notification:") {
                notificationIDs.append(String(id.dropFirst("notification:".count)))
            } else if id.hasPrefix("request:") {
                requestIDs.append(id)
            } else {
                throw JSONRPCError.invalidParams
            }
        }
        let stamp = acknowledged ? Date() : nil
        var updated = Set<String>()
        for runID in try AgentRunResultRepository(db: db).setFailureAcknowledged(runIds: Array(runIDs.keys), at: stamp) {
            if let id = runIDs[runID] { updated.insert(id) }
        }
        if !runIDs.isEmpty {
            let origins = try ActivityOriginProjection.load(db: db, threads: AgentThreadRepository(db: db).list())
            for runID in runIDs.keys {
                for itemID in origins.botFailureIDsByRunID[runID.description] ?? [] {
                    botAttentionIDs[itemID] = "bot-attention:\(itemID.value.uuidString.lowercased())"
                }
            }
        }
        // Runs still marked running with no live process (Needs you), and requests, keep
        // their cleared mark in the activity ledger under a key that outlives the item id.
        var ledgerKeys = [(itemID: String, key: String)]()
        for (runID, id) in runIDs where !updated.contains(id) {
            if try isOrphanedRunningRun(runID) { ledgerKeys.append((id, Self.orphanRunLedgerKey(runID))) }
        }
        if !requestIDs.isEmpty {
            var keyByItemID = [String: String]()
            for callback in try ProviderPendingCallbackRepository(db: db).list(states: [.pending, .stale]) {
                let activeRun = callback.state == .pending ? activeRunIDProvider(callback.threadId) : nil
                keyByItemID[Self.requestItemID(callback, activeRun: activeRun)] = Self.requestLedgerKey(callback)
            }
            for id in requestIDs {
                if let key = keyByItemID[id] { ledgerKeys.append((id, key)) }
            }
        }
        if !ledgerKeys.isEmpty {
            let timestamp = stamp.map(Self.isoFractionalString)
            try db.performSync { database in
                try database.transaction {
                    let statement = try database.prepare(timestamp == nil
                        ? "UPDATE activity_notification_state SET acknowledged_at = NULL WHERE item_id = ?;"
                        : "INSERT INTO activity_notification_state(item_id, acknowledged_at) VALUES (?, ?) ON CONFLICT(item_id) DO UPDATE SET acknowledged_at = excluded.acknowledged_at;")
                    for entry in ledgerKeys {
                        try statement.bind(1, entry.key)
                        if let timestamp { try statement.bind(2, timestamp) }
                        _ = try statement.step()
                        statement.reset()
                    }
                }
            }
            updated.formUnion(ledgerKeys.map(\.itemID))
        }
        for itemID in try BotStore(db: db).setAttentionAcknowledged(ids: Array(botAttentionIDs.keys), at: stamp) {
            if let id = botAttentionIDs[itemID] { updated.insert(id) }
        }
        if !scheduledIDs.isEmpty || !notificationIDs.isEmpty {
            let timestamp = stamp.map(Self.isoFractionalString)
            let changed = try db.performSync { database in
                try database.transaction {
                    var changed = [String]()
                    let reopen = try database.prepare("UPDATE activity_notification_state SET acknowledged_at = NULL WHERE item_id = ?;")
                    let occurrence = try database.prepare("SELECT status FROM scheduled_task_runs WHERE id = ? AND agent_run_id IS NULL;")
                    let acknowledgeOccurrence = try database.prepare("INSERT INTO activity_notification_state(item_id, acknowledged_at) VALUES (?, ?) ON CONFLICT(item_id) DO UPDATE SET acknowledged_at = excluded.acknowledged_at;")
                    for occurrenceID in scheduledIDs {
                        try occurrence.bind(1, occurrenceID)
                        let failed = try occurrence.step() && occurrence.columnText(0) == "failed"
                        occurrence.reset()
                        guard failed else { continue }
                        let statement = timestamp == nil ? reopen : acknowledgeOccurrence
                        try statement.bind(1, "activity:scheduled-occurrence:\(occurrenceID)")
                        if let timestamp { try statement.bind(2, timestamp) }
                        _ = try statement.step()
                        statement.reset()
                        changed.append("scheduled-occurrence:\(occurrenceID)")
                    }
                    let note = try database.prepare("SELECT category, read_at FROM notifications WHERE id = ? AND dismissed_at IS NULL;")
                    let acknowledgeNote = try database.prepare("INSERT INTO activity_notification_state(item_id, viewed_at, acknowledged_at) VALUES (?, ?, ?) ON CONFLICT(item_id) DO UPDATE SET acknowledged_at = excluded.acknowledged_at;")
                    for notificationID in notificationIDs {
                        try note.bind(1, notificationID)
                        let found = try note.step()
                        let category = found ? note.columnText(0).flatMap(PetNotificationCategory.init(rawValue:)) : nil
                        let isFailure = category.map(Self.notificationFailureCategories.contains) == true
                        // An unread needs-you notice (file conflict) is in Needs you too.
                        let isOpenNeedsYou = !isFailure && category?.classification == .needsYou && note.columnText(1) == nil
                        let priorViewed = isFailure ? note.columnText(1) : nil
                        note.reset()
                        guard isFailure || isOpenNeedsYou else { continue }
                        if let timestamp {
                            try acknowledgeNote.bind(1, notificationID)
                            try acknowledgeNote.bind(2, priorViewed)
                            try acknowledgeNote.bind(3, timestamp)
                            _ = try acknowledgeNote.step()
                            acknowledgeNote.reset()
                        } else {
                            try reopen.bind(1, notificationID)
                            _ = try reopen.step()
                            reopen.reset()
                        }
                        changed.append("notification:\(notificationID)")
                    }
                    return changed
                }
            }
            updated.formUnion(changed)
        }
        return ids.filter(updated.contains)
    }

    private struct RunRow {
        let runID: AgentRunID
        let threadID: AgentThreadID
        let status: String
        let terminalReason: String
        let startedAt: Date
        let finishedAt: Date?
        let error: String?
    }

    private func allRuns(threadByID: [String: AgentThread]) throws -> [RunRow] {
        try readDB.performSync { db in
            let statement = try db.prepare("SELECT id, thread_id, status, started_at, finished_at, error_message, terminal_reason FROM agent_runs ORDER BY started_at DESC;")
            var rows = [RunRow]()
            while try statement.step() {
                guard let runRaw = statement.columnText(0), let runUUID = UUID(uuidString: runRaw),
                      let threadRaw = statement.columnText(1), let thread = threadByID[threadRaw],
                      let startedRaw = statement.columnText(3), let started = Self.parseDate(startedRaw),
                      let status = statement.columnText(2) else { continue }
                rows.append(RunRow(runID: AgentRunID(runUUID), threadID: thread.id, status: status,
                                   terminalReason: statement.columnText(6) ?? "", startedAt: started,
                                   finishedAt: statement.columnText(4).flatMap(Self.parseDate), error: statement.columnText(5)))
            }
            return rows
        }
    }

    private struct CheckpointEvidence { let turnCount: Int; let files: [String] }
    private func checkpointEvidence(runIDs: [AgentRunID]) throws -> [String: CheckpointEvidence] {
        guard !runIDs.isEmpty else { return [:] }
        return try readDB.performSync { db in
            var evidence = [String: CheckpointEvidence]()
            for start in stride(from: 0, to: runIDs.count, by: 500) {
                let batch = Array(runIDs[start..<min(start + 500, runIDs.count)])
                let statement = try db.prepare("SELECT run_id, checkpoint_turn_count, files_json FROM agent_turn_checkpoints WHERE run_id IN (\(Array(repeating: "?", count: batch.count).joined(separator: ","))) ORDER BY completed_at DESC;")
                for (offset, runID) in batch.enumerated() { try statement.bind(Int32(offset + 1), runID.description) }
                while try statement.step() {
                    guard let runID = statement.columnText(0), evidence[runID] == nil else { continue }
                    let turnCount = Int(statement.columnInt64(1))
                    let filesJSON = statement.columnText(2) ?? "[]"
                    let files = (try? JSONDecoder().decode([AgentTurnCheckpointFile].self, from: Data(filesJSON.utf8)))?.map(\.path) ?? []
                    evidence[runID] = CheckpointEvidence(turnCount: turnCount, files: files)
                }
            }
            return evidence
        }
    }

    private struct NotificationState { let viewedAt: Date?; let acknowledgedAt: Date? }

    private func loadNotificationStates(db: SQLiteDB) throws -> [String: NotificationState] {
        try db.performSync { database in
            let statement = try database.prepare("SELECT item_id, viewed_at, acknowledged_at FROM activity_notification_state;")
            defer { statement.reset() }
            var states = [String: NotificationState]()
            while try statement.step() {
                let id = statement.columnText(0) ?? ""
                states[id] = NotificationState(
                    viewedAt: statement.columnText(1).flatMap(Self.parseDate),
                    acknowledgedAt: statement.columnText(2).flatMap(Self.parseDate)
                )
            }
            return states
        }
    }

    private func isOrphanedRunningRun(_ runID: AgentRunID) throws -> Bool {
        let row = try db.performSync { database -> (thread: String, status: String)? in
            let statement = try database.prepare("SELECT thread_id, status FROM agent_runs WHERE id = ?;")
            defer { statement.reset() }
            try statement.bind(1, runID.description)
            guard try statement.step(), let thread = statement.columnText(0), let status = statement.columnText(1) else { return nil }
            return (thread, status)
        }
        guard let row, row.status == "running",
              let threadUUID = UUID(uuidString: row.thread) else { return false }
        return activeRunIDProvider(AgentThreadID(threadUUID)) != runID
    }

    private static func requestItemID(_ callback: ProviderPendingCallback, activeRun: AgentRunID?) -> String {
        activeRun.map { "request:\($0.description):\(callback.requestId)" }
            ?? "request:\(callback.threadId.description):\(callback.requestId)"
    }

    private static func requestLedgerKey(_ callback: ProviderPendingCallback) -> String {
        "activity:request:\(callback.threadId.description):\(callback.requestId)"
    }

    private static func orphanRunLedgerKey(_ runID: AgentRunID) -> String {
        "activity:orphan-run:\(runID.description)"
    }

    private static let notificationFailureCategories: Set<PetNotificationCategory> = [
        .gitFailed, .projectScriptFailed, .sshTransferFailed, .providerUpdateFailed, .serverListenerFailed
    ]

    private static func notificationSummary(_ value: String?) -> String? {
        value.flatMap(AgentRunResultRepository.safeSummary)
    }

    private static func notificationPayload(_ body: String?) -> (runID: String?, requestID: String?, threadID: String?, activitySummary: String?) {
        guard let body, let data = body.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, nil, nil, nil) }
        let run = (object["run_id"] as? String).flatMap { UUID(uuidString: $0)?.uuidString }
        let request = object["request_id"] as? String
        return (run, request, (object["thread_id"] as? String).flatMap { UUID(uuidString: $0)?.uuidString }, object["activity_summary"] as? String)
    }
    private static func counts(for items: [AgentActivityItem]) -> AgentActivityCounts {
        AgentActivityCounts(
            running: items.filter { $0.state == .running && !$0.blocking }.count,
            queued: items.filter { $0.state == .queued }.count,
            needsYou: items.filter(\.needsAction).count,
            finished: items.filter { Self.isTerminal($0.state) }.count,
            newResults: items.filter(Self.isJustFinished).count
        )
    }
    private static func workspaceCounts(for items: [AgentActivityItem]) -> [String: AgentActivityCounts] {
        Dictionary(grouping: items.compactMap { item in
            item.workspaceID.map { ($0.uuidString, item) }
        }, by: { $0.0 }).mapValues { Self.counts(for: $0.map { $0.1 }) }
    }

    /// Results keep only the newest terminal items that need no action. This is a view cap:
    /// rows stay in the database, and an item that still needs action is never dropped.
    static let resultsLimit = 99
    static func applyingResultsLimit(_ items: [AgentActivityItem]) -> [AgentActivityItem] {
        let results = items.filter { Self.isTerminal($0.state) && !$0.needsAction }.sorted(by: Self.activityOrder)
        let kept = Set(results.prefix(resultsLimit).map(\.id))
        return items.filter { !Self.isTerminal($0.state) || $0.needsAction || kept.contains($0.id) }
    }

    private static let terminalRunStatuses: Set<String> = ["completed", "failed", "interrupted", "cancelled"]
    /// Finished and not opened yet: the Just finished tab and the `new_results` count.
    private static func isJustFinished(_ item: AgentActivityItem) -> Bool {
        item.finishedAt != nil && item.viewedAt == nil
    }

    private static func isTerminal(_ state: AgentActivityState) -> Bool {
        [.completed, .failed, .interrupted, .stopped, .expired].contains(state)
    }
    private static func activityOrder(_ lhs: AgentActivityItem, _ rhs: AgentActivityItem) -> Bool {
        lhs.occurredAt == rhs.occurredAt ? lhs.id < rhs.id : lhs.occurredAt > rhs.occurredAt
    }
    // One list parses several thousand timestamps. A formatter per call made that take over a
    // second, and ISO8601DateFormatter itself costs ~100 µs a parse, so the format styles go
    // first; the formatters (documented thread-safe) stay as the fallback for odd inputs.
    private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainStyle = Date.ISO8601FormatStyle()
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainFormatter = ISO8601DateFormatter()

    nonisolated private static func isoFractionalString(_ date: Date) -> String {
        fractionalFormatter.string(from: date)
    }
    nonisolated fileprivate static func parseDate(_ value: String) -> Date? {
        (try? plainStyle.parse(value)) ?? (try? fractionalStyle.parse(value))
            ?? fractionalFormatter.date(from: value) ?? plainFormatter.date(from: value)
    }
    private static func json<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, output in
            var container = output.singleValueContainer()
            try container.encode(fractionalFormatter.string(from: date))
        }
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }
}

private struct ActivityFilter {
    let workspaceID: UUID?
    let section: String
    let search: String
    let outcome: String?
    let since: Date?
    let cursor: String?
    let limit: Int
    init(params: [String: JSONValue]) throws {
        if let raw = params["workspace_id"]?.stringValue, let uuid = UUID(uuidString: raw) { workspaceID = uuid }
        else if params["workspace_id"] != nil { throw JSONRPCError.invalidParams }
        else { workspaceID = nil }
        section = params["section"]?.stringValue ?? "all"
        guard ["all", "running", "needs_you", "just_finished", "finished"].contains(section) else { throw JSONRPCError.invalidParams }
        search = params["search"]?.stringValue?.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) ?? ""
        outcome = params["outcome"]?.stringValue
        guard outcome == nil || ["completed", "failed", "interrupted", "stopped"].contains(outcome!) else { throw JSONRPCError.invalidParams }
        if let value = params["since"]?.stringValue { since = ActivityService.parseDate(value); guard since != nil else { throw JSONRPCError.invalidParams } } else { since = nil }
        cursor = params["cursor"]?.stringValue
        let requested = params["limit"]?.intValue ?? 50
        guard requested > 0 else { throw JSONRPCError.invalidParams }
        // Bulk actions read a whole filter; 500 per page keeps that to a few passes.
        limit = min(requested, 500)
    }
    func matches(_ item: AgentActivityItem) -> Bool {
        if let workspaceID, item.workspaceID != workspaceID { return false }
        if let since, item.occurredAt < since { return false }
        if let outcome, item.state.rawValue != outcome { return false }
        return search.isEmpty || item.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(search) || (item.summary?.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(search) ?? false)
    }
}

private struct ActivityCursor {
    let occurredAt: Date
    let id: String
    let snapshotAt: Date
    init(occurredAt: Date, id: String, snapshotAt: Date) {
        self.occurredAt = occurredAt; self.id = id; self.snapshotAt = snapshotAt
    }
    init?(rawValue: String) {
        guard let data = Data(base64Encoded: rawValue),
              let object = try? JSONDecoder().decode(CursorWire.self, from: data) else { return nil }
        occurredAt = Date(timeIntervalSince1970: Double(bitPattern: object.occurredAtBits))
        snapshotAt = Date(timeIntervalSince1970: Double(bitPattern: object.snapshotBits))
        id = object.id
    }
    var rawValue: String {
        let wire = CursorWire(occurredAtBits: occurredAt.timeIntervalSince1970.bitPattern,
                              snapshotBits: snapshotAt.timeIntervalSince1970.bitPattern, id: id)
        return (try? JSONEncoder().encode(wire).base64EncodedString()) ?? ""
    }
    private struct CursorWire: Codable { let occurredAtBits: UInt64; let snapshotBits: UInt64; let id: String }
}

/// Emits `agent.activity.changed` for rows whose state changed. Each workspace publishes
/// at most once per `minInterval`; changes inside the window coalesce into one trailing event.
final class ActivityChangeEmitter: @unchecked Sendable {
    static let shared = ActivityChangeEmitter()
    static let minInterval: TimeInterval = 0.5

    struct Row: Equatable {
        let workspace: String?
        let thread: String?
        let fingerprint: String
    }

    private let lock = NSLock()
    private var rows: [String: Row] = [:]
    private var latestCounts: [String: AgentActivityCounts] = [:]
    private var pendingThreads: [String: Set<String>] = [:]
    private var lastPublished: [String: Date] = [:]
    private var scheduled: Set<String> = []
    /// The first observation is the baseline, not a change.
    private var primed = false

    static func row(for item: AgentActivityItem) -> Row {
        Row(
            workspace: item.workspaceID?.uuidString,
            thread: item.threadID?.uuidString,
            fingerprint: "\(item.state.rawValue)|\(item.needsAction)|\(item.blocking)|\(item.viewedAt != nil)|\(item.occurredAt.timeIntervalSince1970)"
        )
    }

    /// Rows that appeared, changed or vanished, grouped by workspace. Rows without a workspace are skipped.
    static func diff(previous: [String: Row], items: [AgentActivityItem]) -> (rows: [String: Row], changedThreads: [String: Set<String>]) {
        var current: [String: Row] = [:]
        var changed: [String: Set<String>] = [:]
        for item in items {
            let row = row(for: item)
            current[item.id] = row
            guard previous[item.id] != row, let workspace = row.workspace else { continue }
            changed[workspace, default: []].insert(row.thread ?? item.id)
        }
        for (id, old) in previous where current[id] == nil {
            guard let workspace = old.workspace else { continue }
            changed[workspace, default: []].insert(old.thread ?? id)
        }
        return (current, changed)
    }

    /// Seconds to wait before the next publish for a workspace; 0 publishes now.
    static func publishDelay(lastPublished: Date?, now: Date) -> TimeInterval {
        guard let lastPublished else { return 0 }
        return max(0, lastPublished.addingTimeInterval(minInterval).timeIntervalSince(now))
    }

    static func payload(workspaceID: String, counts: AgentActivityCounts, changedThreadIDs: Set<String>) -> JSONValue {
        .object([
            "workspace_id": .string(workspaceID),
            "counts": .object([
                "running": .number(Double(counts.running)),
                "queued": .number(Double(counts.queued)),
                "needs_you": .number(Double(counts.needsYou)),
                "finished": .number(Double(counts.finished)),
                "new_results": .number(Double(counts.newResults)),
            ]),
            "changed_thread_ids": .array(changedThreadIDs.sorted().map(JSONValue.string)),
        ])
    }

    func observe(items: [AgentActivityItem], byWorkspace: [String: AgentActivityCounts], now: Date = Date()) {
        lock.lock()
        let diffed = Self.diff(previous: rows, items: items)
        rows = diffed.rows
        latestCounts = byWorkspace
        guard primed else {
            primed = true
            lock.unlock()
            return
        }
        var immediate: [String] = []
        for (workspace, threads) in diffed.changedThreads {
            pendingThreads[workspace, default: []].formUnion(threads)
            if scheduled.contains(workspace) { continue }
            let delay = Self.publishDelay(lastPublished: lastPublished[workspace], now: now)
            if delay <= 0 {
                immediate.append(workspace)
            } else {
                scheduled.insert(workspace)
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in flush(workspace) }
            }
        }
        lock.unlock()
        for workspace in immediate { flush(workspace) }
    }

    private func flush(_ workspace: String) {
        lock.lock()
        let threads = pendingThreads.removeValue(forKey: workspace) ?? []
        scheduled.remove(workspace)
        lastPublished[workspace] = Date()
        let counts = latestCounts[workspace] ?? AgentActivityCounts(running: 0, queued: 0, needsYou: 0, finished: 0, newResults: 0)
        lock.unlock()
        guard !threads.isEmpty else { return }
        EventBus.shared.publish(
            kind: .agentActivityChanged,
            payload: Self.payload(workspaceID: workspace, counts: counts, changedThreadIDs: threads)
        )
    }
}
