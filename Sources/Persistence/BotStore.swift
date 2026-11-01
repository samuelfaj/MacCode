import Foundation
import CoreModel
import os

public enum BotStoreError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case notFound
    case invalidRow(String)
    case revisionConflict
    case invalidInput(String)

    public var description: String {
        switch self {
        case .notFound: return "Bot was not found."
        case .invalidRow(let message): return "Invalid bot row: \(message)"
        case .revisionConflict: return "This changed somewhere else. Reload and try again."
        case .invalidInput(let message): return message
        }
    }

    public var errorDescription: String? { description }
}

public struct BotQueuedFollowUpRecord: Equatable, Sendable {
    public var id: String
    public var botID: BotID
    public var conversationID: String?
    public var text: String
    public var payloadJSON: String
    public var sortOrder: Int
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        botID: BotID,
        conversationID: String? = nil,
        text: String,
        payloadJSON: String = "{}",
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.botID = botID
        self.conversationID = conversationID
        self.text = text
        self.payloadJSON = payloadJSON
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

public final class BotStore: @unchecked Sendable {
    private static let lookupBatchSize = 200
    // These values satisfy the pre-thread-routing NOT NULL columns only. They
    // are never decoded into BotRevision or consulted as an execution route.
    private static let legacyProviderColumnValue: AgentProvider = .codex
    private static let legacyProviderInstanceColumnValue = ""
    private static let legacyModelColumnValue = ""
    private static let legacyReasoningEffortColumnValue: AgentReasoningEffort = .medium
    private static let legacyCompatibleRouteSetColumnValue = ["default"]

    let db: SQLiteDB
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
#if DEBUG
    var onBeforePublishCommitForTesting: (() throws -> Void)?
#endif
    /// Called after a bot delete commits, with the ids of the group turns the
    /// delete cancelled. Every delete path (Bots window, paired remote) goes
    /// through `delete(id:)`, so the group orchestrator hears of each one.
    public var onBotDeleted: ((BotID, [BotGroupTurnID]) -> Void)?
    private let dates = LockedISO8601Formatter({
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }())

    public init(db: SQLiteDB) {
        self.db = db
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    // MARK: - Cached bot list

    /// Guards `botsListRevisionValue` / `cachedBotList` / the DEBUG query
    /// counter. Kept off the db queue so cached reads never wait behind the
    /// SQLite writer.
    private let listCacheState = NSLock()
    private var botsListRevisionValue: UInt64 = 0
    private var cachedBotList: (revision: UInt64, includeHidden: Bool, bots: [BotDefinition])?
#if DEBUG
    public private(set) var listQueryCountForTesting = 0
    /// Rows inserted into `bot_queued_follow_ups`, under the same lock. One
    /// queued message must write one row, not every Bot's queue again.
    public private(set) var queuedFollowUpRowWriteCountForTesting = 0
#endif

    /// In-memory `linked_agent_thread_id → bot` map so run-status broadcasts
    /// can skip SQLite for threads that never belonged to a bot.
    private let linkedThreadCacheState = NSLock()
    private var botIDByLinkedThread: [AgentThreadID: BotID] = [:]
    private var linkedThreadByConversation: [BotConversationID: AgentThreadID] = [:]
    public private(set) var conversationLinkedQueryCountForTesting = 0

    /// Hot-path lookup. Does not touch SQLite.
    public func cachedBotID(linkedTo threadID: AgentThreadID) -> BotID? {
        linkedThreadCacheState.withLock { botIDByLinkedThread[threadID] }
    }

    private func rememberLinkedThread(_ conversation: BotConversation) {
        linkedThreadCacheState.withLock {
            if let previous = linkedThreadByConversation[conversation.id],
               previous != conversation.linkedAgentThreadID,
               botIDByLinkedThread[previous] == conversation.botID {
                botIDByLinkedThread[previous] = nil
            }
            if let threadID = conversation.linkedAgentThreadID {
                botIDByLinkedThread[threadID] = conversation.botID
                linkedThreadByConversation[conversation.id] = threadID
            } else {
                linkedThreadByConversation[conversation.id] = nil
            }
        }
    }

    private func forgetLinkedThreads(botID: BotID) {
        linkedThreadCacheState.withLock {
            botIDByLinkedThread = botIDByLinkedThread.filter { $0.value != botID }
        }
    }

    func forgetLinkedThreads(_ threadIDs: [AgentThreadID]) {
        let forgotten = Set(threadIDs)
        linkedThreadCacheState.withLock {
            for threadID in forgotten { botIDByLinkedThread[threadID] = nil }
            linkedThreadByConversation = linkedThreadByConversation.filter { !forgotten.contains($0.value) }
        }
    }

    /// Monotonic revision of bot-definition writes (create, updateProfile,
    /// renameHandle, setPinned, setHidden, publish, duplicate, delete) and
    /// context grants/revokes, which change where a Bot can be mentioned.
    public var botsListRevision: UInt64 {
        listCacheState.withLock { botsListRevisionValue }
    }

    func bumpBotsListRevision() {
        listCacheState.withLock { botsListRevisionValue += 1 }
    }

    /// `list()` served from an in-memory cache; re-queries only after a bot
    /// write bumped the revision. Hot main-thread callers (composer
    /// suggestions, transcript mention rows) must not touch SQLite per body
    /// pass or per keystroke while a run is streaming (perf audit AA-01).
    public func listCached(includeHidden: Bool = false) throws -> [BotDefinition] {
        let revisionAtStart = botsListRevision
        let cachedHit = listCacheState.withLock { () -> [BotDefinition]? in
            if let cached = cachedBotList,
               cached.revision == revisionAtStart,
               cached.includeHidden == includeHidden {
                return cached.bots
            }
            return nil
        }
        if let cachedHit { return cachedHit }
        let bots = try list(includeHidden: includeHidden)
        // A write that raced the query bumps the revision; do not cache under
        // the stale tag, the next call refreshes.
        listCacheState.withLock {
            if botsListRevisionValue == revisionAtStart {
                cachedBotList = (revisionAtStart, includeHidden, bots)
            }
        }
        return bots
    }

    public func list(includeHidden: Bool = false, includeDeleted: Bool = false) throws -> [BotDefinition] {
#if DEBUG
        listCacheState.withLock { listQueryCountForTesting += 1 }
#endif
        return try db.performSync { database in
            var sql = try botSelect(database) + " WHERE 1=1"
            if !includeDeleted { sql += " AND deleted_at IS NULL" }
            if !includeHidden { sql += " AND (hidden = 0 OR deleted_at IS NOT NULL)" }
            sql += " ORDER BY updated_at DESC;"
            let statement = try database.prepare(sql)
            defer { statement.reset() }
            var result: [BotDefinition] = []
            while try statement.step() { result.append(try decodeBot(statement)) }
            return result
        }
    }

    public func get(id: BotID) throws -> BotDefinition? {
        try db.performSync { database in
            try loadBot(id: id, database: database)
        }
    }

    public func bots(ids: Set<BotID>) throws -> [BotID: BotDefinition] {
        guard !ids.isEmpty else { return [:] }
        let ids = Array(ids)
        return try db.performSync { database in
            var bots: [BotID: BotDefinition] = [:]
            for start in stride(from: 0, to: ids.count, by: Self.lookupBatchSize) {
                let batch = ids[start..<min(start + Self.lookupBatchSize, ids.count)]
                let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
                let statement = try database.prepare(try botSelect(database) + " WHERE id IN (\(marks));")
                defer { statement.reset() }
                for (index, id) in batch.enumerated() {
                    try statement.bind(Int32(index + 1), id.value.uuidString.lowercased())
                }
                while try statement.step() {
                    guard let bot = try? decodeBot(statement) else { continue }
                    bots[bot.id] = bot
                }
            }
            return bots
        }
    }

    public func getRevision(id: BotRevisionID) throws -> BotRevision? {
        try db.performSync { database in
            let statement = try database.prepare(Self.revisionSelect + " WHERE id = ? LIMIT 1;")
            defer { statement.reset() }
            try statement.bind(1, id.value.uuidString.lowercased())
            return try statement.step() ? try decodeRevision(statement) : nil
        }
    }

    public func create(
        name: String,
        title: String,
        description: String,
        handle: String? = nil,
        avatarSymbol: String = BotBlobatarSpec.default.token,
        soul: String = "",
        desktopKind: BotDesktopKind = .logicalExecutionSpace,
        workspaceID: WorkspaceID? = nil,
        notificationsEnabled: Bool = true,
        now: Date = Date()
    ) throws -> BotDefinition {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw BotPublishError.invalidRevision }
        let draft = BotRevisionDraft(
            name: trimmedName,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            soul: soul,
            permissionMode: .fullAccess,
            desktopKind: desktopKind
        )
        let botID = BotID()
        let revisionID = BotRevisionID()
        let revision = makeRevision(
            id: revisionID,
            botID: botID,
            revisionNumber: 1,
            draft: draft,
            publishedAt: now,
            supersedes: nil
        )
        var created: BotDefinition!
        try db.transaction {
            try assertLiveCapacity(database: db, additional: 1)
            let resolvedHandle: String
            if let handle {
                resolvedHandle = try resolveHandle(handle, fallback: trimmedName)
                try assertHandleAvailable(resolvedHandle, database: db)
            } else {
                resolvedHandle = try allocateUniqueHandle(stem: trimmedName, database: db)
            }
            let bot = BotDefinition(
                id: botID,
                handle: resolvedHandle,
                name: draft.name,
                title: draft.title,
                description: draft.description,
                avatarSymbol: avatarSymbol,
                currentRevisionID: revisionID,
                directoryEpoch: 1,
                notificationsEnabled: notificationsEnabled,
                createdAt: now,
                updatedAt: now,
                workspaceID: workspaceID
            )
            created = bot
            try insertBot(bot, currentRevisionID: nil, database: db)
            try insertRevision(revision, database: db)
            try setCurrentRevision(
                botID: botID,
                revisionID: revisionID,
                name: draft.name,
                title: draft.title,
                description: draft.description,
                avatarSymbol: avatarSymbol,
                notificationsEnabled: notificationsEnabled,
                updatedAt: now,
                database: db
            )
            try insertLiveHandle(bot.handle, botID: botID, at: now, database: db)
        }
        bumpBotsListRevision()
        return created
    }

    @available(*, deprecated, message: "Provider routing belongs to AgentThread, not BotStore.create.")
    public func create(
        name: String,
        title: String,
        description: String,
        handle: String? = nil,
        avatarSymbol: String = BotBlobatarSpec.default.token,
        soul: String = "",
        provider _: AgentProvider,
        providerInstanceID _: String? = nil,
        model _: String = "",
        reasoningEffort _: AgentReasoningEffort = .medium,
        compatibleRouteSet _: [String] = ["default"],
        desktopKind: BotDesktopKind = .logicalExecutionSpace,
        workspaceID: WorkspaceID? = nil,
        notificationsEnabled: Bool = true,
        now: Date = Date()
    ) throws -> BotDefinition {
        try create(
            name: name,
            title: title,
            description: description,
            handle: handle,
            avatarSymbol: avatarSymbol,
            soul: soul,
            desktopKind: desktopKind,
            workspaceID: workspaceID,
            notificationsEnabled: notificationsEnabled,
            now: now
        )
    }

    public func updateProfile(
        id: BotID,
        name: String? = nil,
        title: String? = nil,
        description: String? = nil,
        avatarSymbol: String? = nil,
        notificationsEnabled: Bool? = nil,
        now: Date = Date()
    ) throws -> BotDefinition {
        let updatedProfile = try db.transaction {
            guard let bot = try loadBot(id: id, database: db), bot.deletedAt == nil else {
                throw BotStoreError.notFound
            }
            guard let currentID = bot.currentRevisionID,
                  let current = try loadRevision(id: currentID, database: db) else {
                throw BotPublishError.invalidRevision
            }
            let nextName = name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? bot.name
            guard !nextName.isEmpty else { throw BotPublishError.invalidRevision }
            let draft = BotRevisionDraft(
                name: nextName,
                title: title.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? current.title,
                description: description.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? current.description,
                soul: current.soul,
                permissionMode: current.permissionMode,
                desktopKind: current.desktopKind
            )
            _ = try publishLocked(
                bot: bot,
                expectedCurrentRevisionID: currentID,
                draft: draft,
                avatarSymbol: avatarSymbol ?? bot.avatarSymbol,
                notificationsEnabled: notificationsEnabled ?? bot.notificationsEnabled,
                now: now,
                database: db
            )
            guard let updated = try loadBot(id: id, database: db) else { throw BotStoreError.notFound }
            return updated
        }
        bumpBotsListRevision()
        return updatedProfile
    }

    public func renameHandle(id: BotID, handle: String, now: Date = Date()) throws -> BotDefinition {
        guard let normalized = BotHandle.normalize(handle) else { throw BotPublishError.handleEmpty }
        let renamed = try db.transaction {
            guard let bot = try loadBot(id: id, database: db), bot.deletedAt == nil else {
                throw BotStoreError.notFound
            }
            if bot.handle == normalized { return bot }
            // Titio is found by its slug (pet, inbox, notice hub): a rename
            // would orphan it and make a second Titio on the next launch.
            if bot.handle == TitioIdentity.handle {
                throw BotStoreError.invalidRow("Titio's slug is fixed.")
            }
            try assertHandleAvailable(normalized, excluding: bot.handle, database: db)
            let updateBot = try db.prepare(
                "UPDATE bots SET handle = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;"
            )
            defer { updateBot.reset() }
            try updateBot.bind(1, normalized)
            try updateBot.bind(2, string(now))
            try updateBot.bind(3, id.value.uuidString.lowercased())
            _ = try updateBot.step()
            let dropOld = try db.prepare("DELETE FROM bot_handles WHERE bot_id = ? AND handle = ?;")
            defer { dropOld.reset() }
            try dropOld.bind(1, id.value.uuidString.lowercased())
            try dropOld.bind(2, bot.handle)
            _ = try dropOld.step()
            try insertLiveHandle(normalized, botID: id, at: now, database: db)
            guard let updated = try loadBot(id: id, database: db) else { throw BotStoreError.notFound }
            return updated
        }
        bumpBotsListRevision()
        return renamed
    }

    public func setPinned(id: BotID, pinned: Bool, now: Date = Date()) throws {
        try db.performSync { database in
            let statement = try database.prepare(
                "UPDATE bots SET pinned = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;"
            )
            defer { statement.reset() }
            try statement.bind(1, pinned)
            try statement.bind(2, string(now))
            try statement.bind(3, id.value.uuidString.lowercased())
            _ = try statement.step()
        }
        bumpBotsListRevision()
    }

    /// Writes sort_order = index for each listed live bot. Live bots not listed
    /// keep their current relative order after the listed ones. Unknown ids throw.
    public func reorder(orderedIDs: [BotID]) throws {
        var seen = Set<BotID>()
        let listed = orderedIDs.filter { seen.insert($0).inserted }
        try db.transaction {
            let select = try db.prepare(try botSelect(db) + " WHERE deleted_at IS NULL;")
            var live: [BotDefinition] = []
            while try select.step() { live.append(try decodeBot(select)) }
            select.reset()
            let liveSet = Set(live.map(\.id))
            guard listed.allSatisfy({ liveSet.contains($0) }) else { throw BotStoreError.notFound }
            let rest = BotOrdering.sorted(live).map(\.id).filter { !seen.contains($0) }
            let statement = try db.prepare("UPDATE bots SET sort_order = ? WHERE id = ? AND deleted_at IS NULL;")
            defer { statement.reset() }
            for (index, id) in (listed + rest).enumerated() {
                statement.reset()
                try statement.bind(1, index)
                try statement.bind(2, id.value.uuidString.lowercased())
                _ = try statement.step()
            }
        }
        bumpBotsListRevision()
    }

    /// Reply style lives on the Bot row, not in revisions: it changes how the
    /// Bot writes and how its chat renders, not who the Bot is.
    @discardableResult
    public func setReplyStyle(
        id: BotID,
        verbosity: BotReplyVerbosity? = nil,
        cavemanEnabled: Bool? = nil,
        now: Date = Date()
    ) throws -> BotDefinition {
        let updated = try db.transaction {
            guard let bot = try loadBot(id: id, database: db), bot.deletedAt == nil else {
                throw BotStoreError.notFound
            }
            let statement = try db.prepare("""
                UPDATE bots SET reply_verbosity = ?, caveman_enabled = ?, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL;
                """)
            defer { statement.reset() }
            try statement.bind(1, (verbosity ?? bot.verbosity).rawValue)
            try statement.bind(2, cavemanEnabled ?? bot.cavemanEnabled)
            try statement.bind(3, string(now))
            try statement.bind(4, id.value.uuidString.lowercased())
            _ = try statement.step()
            guard let updated = try loadBot(id: id, database: db) else { throw BotStoreError.notFound }
            return updated
        }
        bumpBotsListRevision()
        return updated
    }

    /// Puts Titio back to its built-in identity, instructions, avatar,
    /// notifications and reply style. Its desktop, conversations, files and
    /// scheduled tasks are untouched.
    @discardableResult
    public func restoreTitioFactorySettings(id: BotID, now: Date = Date()) throws -> BotDefinition {
        guard let bot = try get(id: id), bot.deletedAt == nil else { throw BotStoreError.notFound }
        // Never overwrite another Bot with Titio.
        guard bot.handle.lowercased() == TitioIdentity.handle else { throw BotPublishError.invalidRevision }
        let current = try bot.currentRevisionID.flatMap { try getRevision(id: $0) }
        _ = try publish(
            botID: id,
            expectedCurrentRevisionID: bot.currentRevisionID,
            draft: BotRevisionDraft(
                name: TitioIdentity.name,
                title: TitioIdentity.title,
                description: TitioIdentity.description,
                soul: TitioIdentity.soul,
                permissionMode: .fullAccess,
                desktopKind: current?.desktopKind ?? .logicalExecutionSpace
            ),
            avatarSymbol: BotBlobatarSpec.default.token,
            notificationsEnabled: true,
            now: now
        )
        return try setReplyStyle(
            id: id,
            verbosity: TitioIdentity.verbosity,
            cavemanEnabled: TitioIdentity.cavemanEnabled,
            now: now
        )
    }

    public func setHidden(id: BotID, hidden: Bool, now: Date = Date()) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                UPDATE bots
                SET hidden = ?, directory_epoch = directory_epoch + 1, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL;
                """)
            defer { statement.reset() }
            try statement.bind(1, hidden)
            try statement.bind(2, string(now))
            try statement.bind(3, id.value.uuidString.lowercased())
            _ = try statement.step()
        }
        bumpBotsListRevision()
    }

    public func publish(
        botID: BotID,
        expectedCurrentRevisionID: BotRevisionID?,
        draft: BotRevisionDraft,
        avatarSymbol: String? = nil,
        notificationsEnabled: Bool? = nil,
        now: Date = Date(),
        beforeCommit: ((BotRevision) throws -> Void)? = nil,
        onRollback: (() throws -> Void)? = nil
    ) throws -> BotRevision {
        var externalMutationApplied = false
        do {
            let published = try db.transaction {
                guard let bot = try loadBot(id: botID, database: db), bot.deletedAt == nil else {
                    throw BotStoreError.notFound
                }
                let revision = try publishLocked(
                    bot: bot,
                    expectedCurrentRevisionID: expectedCurrentRevisionID,
                    draft: draft,
                    avatarSymbol: avatarSymbol ?? bot.avatarSymbol,
                    notificationsEnabled: notificationsEnabled ?? bot.notificationsEnabled,
                    now: now,
                    database: db
                )
                try beforeCommit?(revision)
                externalMutationApplied = beforeCommit != nil
#if DEBUG
                try onBeforePublishCommitForTesting?()
#endif
                return revision
            }
            bumpBotsListRevision()
            return published
        } catch {
            if externalMutationApplied { try onRollback?() }
            throw error
        }
    }

    public func duplicate(id: BotID, now: Date = Date()) throws -> BotDefinition {
        let duplicated = try db.transaction {
            guard let source = try loadBot(id: id, database: db), source.deletedAt == nil else {
                throw BotStoreError.notFound
            }
            try assertLiveCapacity(database: db, additional: 1)
            guard let currentID = source.currentRevisionID,
                  let current = try loadRevision(id: currentID, database: db) else {
                throw BotPublishError.invalidRevision
            }
            let copyName = "\(source.name) copy"
            let handle = try allocateUniqueHandle(stem: source.handle + "-copy", database: db)
            let botID = BotID()
            let revisionID = BotRevisionID()
            let draft = BotRevisionDraft(
                name: copyName,
                title: current.title,
                description: current.description,
                soul: current.soul,
                permissionMode: current.permissionMode,
                desktopKind: current.desktopKind
            )
            let revision = makeRevision(
                id: revisionID,
                botID: botID,
                revisionNumber: 1,
                draft: draft,
                publishedAt: now,
                supersedes: nil
            )
            let copy = BotDefinition(
                id: botID,
                handle: handle,
                name: copyName,
                title: current.title,
                description: current.description,
                avatarSymbol: source.avatarSymbol,
                currentRevisionID: revisionID,
                directoryEpoch: 1,
                notificationsEnabled: source.notificationsEnabled,
                verbosity: source.verbosity,
                cavemanEnabled: source.cavemanEnabled,
                createdAt: now,
                updatedAt: now,
                workspaceID: source.workspaceID
            )
            try insertBot(copy, currentRevisionID: nil, database: db)
            try insertRevision(revision, database: db)
            try setCurrentRevision(
                botID: botID,
                revisionID: revisionID,
                name: copyName,
                title: current.title,
                description: current.description,
                avatarSymbol: source.avatarSymbol,
                notificationsEnabled: source.notificationsEnabled,
                updatedAt: now,
                database: db
            )
            try insertLiveHandle(handle, botID: botID, at: now, database: db)
            try writeExecutionDestination(executionDestination(botID: source.id), botID: botID)
            for binding in try loadSkillBindings(botID: source.id, database: db) {
                try upsertSkillBinding(
                    BotSkillBinding(
                        botID: botID,
                        skillID: binding.skillID,
                        enabled: binding.enabled,
                        digest: binding.digest,
                        updatedAt: now
                    ),
                    database: db
                )
            }
            let routines = try loadRoutines(botID: source.id, database: db)
            for routine in routines {
                let newID = BotRoutineID()
                let definition = BotRoutineDefinition(
                    id: newID,
                    botID: botID,
                    name: routine.definition.name,
                    prompt: routine.definition.prompt,
                    scheduleNote: routine.definition.scheduleNote,
                    scheduleSpecJSON: routine.definition.scheduleSpecJSON,
                    createdAt: now,
                    updatedAt: now
                )
                try insertRoutine(definition, database: db)
                try upsertActivation(
                    BotRoutineActivation(
                        routineID: newID,
                        botID: botID,
                        isEnabled: routine.activation.isEnabled,
                        lastTestRunRequestedAt: nil,
                        updatedAt: now
                    ),
                    database: db
                )
            }
            return copy
        }
        bumpBotsListRevision()
        return duplicated
    }

    public func delete(id: BotID, now: Date = Date()) throws {
        let cancelledTurnIDs: [BotGroupTurnID]? = try db.transaction {
            guard let bot = try loadBot(id: id, database: db) else { throw BotStoreError.notFound }
            if bot.deletedAt != nil { return nil }
            let update = try db.prepare("""
                UPDATE bots
                SET deleted_at = ?, hidden = 1, directory_epoch = directory_epoch + 1, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL;
                """)
            defer { update.reset() }
            try update.bind(1, string(now))
            try update.bind(2, string(now))
            try update.bind(3, id.value.uuidString.lowercased())
            _ = try update.step()

            let dropHandle = try db.prepare("DELETE FROM bot_handles WHERE bot_id = ?;")
            defer { dropHandle.reset() }
            try dropHandle.bind(1, id.value.uuidString.lowercased())
            _ = try dropHandle.step()

            let tombstone = try db.prepare("""
                INSERT OR IGNORE INTO bot_handle_tombstones(handle, bot_id, deleted_at)
                VALUES(?, ?, ?);
                """)
            defer { tombstone.reset() }
            try tombstone.bind(1, bot.handle)
            try tombstone.bind(2, id.value.uuidString.lowercased())
            try tombstone.bind(3, string(now))
            _ = try tombstone.step()

            let acknowledgeAttention = try db.prepare("""
                UPDATE bot_attention_items
                SET acknowledged_at = COALESCE(acknowledged_at, ?)
                WHERE bot_id = ?;
                """)
            defer { acknowledgeAttention.reset() }
            try acknowledgeAttention.bind(1, string(now))
            try acknowledgeAttention.bind(2, id.value.uuidString.lowercased())
            _ = try acknowledgeAttention.step()

            try executeBound("DELETE FROM bot_conversations WHERE bot_id = ?;", id: id)
            try executeBound("DELETE FROM bot_skill_bindings WHERE bot_id = ?;", id: id)
            try executeBound("DELETE FROM bot_routine_activations WHERE bot_id = ?;", id: id)
            try executeBound("DELETE FROM bot_routine_definitions WHERE bot_id = ?;", id: id)
            try executeBound("DELETE FROM bot_queued_follow_ups WHERE bot_id = ?;", id: id)
            return try removeFromTeamsAndGroupsLocked(botID: id, now: now)
        }
        forgetLinkedThreads(botID: id)
        bumpBotsListRevision()
        if let cancelledTurnIDs { onBotDeleted?(id, cancelledTurnIDs) }
    }

    public func listLinkedAgentThreadIDs() throws -> Set<AgentThreadID> {
        try db.performSync { database in
            // Group room threads are bot-owned too: they must never surface as
            // ordinary Agent App threads (Pet, Active Threads).
            let statement = try database.prepare("""
                SELECT linked_agent_thread_id FROM bot_conversations WHERE linked_agent_thread_id IS NOT NULL
                UNION
                SELECT room_thread_id FROM bot_group_conversations;
                """)
            defer { statement.reset() }
            var ids = Set<AgentThreadID>()
            while try statement.step() {
                guard let raw = statement.columnText(0),
                      let uuid = UUID(uuidString: raw) else { continue }
                ids.insert(AgentThreadID(uuid))
            }
            return ids
        }
    }

    public func conversation(id: BotConversationID) throws -> BotConversation? {
        try db.performSync { database in
            let statement = try database.prepare(
                Self.conversationSelect + " WHERE id = ? LIMIT 1;"
            )
            defer { statement.reset() }
            try statement.bind(1, id.value.uuidString.lowercased())
            return try statement.step() ? try decodeConversation(statement) : nil
        }
    }

    public func conversations(ids: Set<BotConversationID>) throws -> [BotConversationID: BotConversation] {
        guard !ids.isEmpty else { return [:] }
        let ids = Array(ids)
        return try db.performSync { database in
            var conversations: [BotConversationID: BotConversation] = [:]
            for start in stride(from: 0, to: ids.count, by: Self.lookupBatchSize) {
                let batch = ids[start..<min(start + Self.lookupBatchSize, ids.count)]
                let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
                let statement = try database.prepare(
                    Self.conversationSelect + " WHERE id IN (\(marks));"
                )
                defer { statement.reset() }
                for (index, id) in batch.enumerated() {
                    try statement.bind(Int32(index + 1), id.value.uuidString.lowercased())
                }
                while try statement.step() {
                    guard let conversation = try? decodeConversation(statement) else { continue }
                    conversations[conversation.id] = conversation
                }
            }
            return conversations
        }
    }

    public func conversationLinked(to threadID: AgentThreadID) throws -> BotConversation? {
        linkedThreadCacheState.withLock { conversationLinkedQueryCountForTesting += 1 }
        return try db.performSync { database in
            let statement = try database.prepare(
                Self.conversationSelect + " WHERE linked_agent_thread_id = ? LIMIT 1;"
            )
            defer { statement.reset() }
            try statement.bind(1, threadID.value.uuidString.lowercased())
            return try statement.step() ? try decodeConversation(statement) : nil
        }
    }

    public func conversationsLinked(
        to threadIDs: Set<AgentThreadID>
    ) throws -> [AgentThreadID: BotConversation] {
        guard !threadIDs.isEmpty else { return [:] }
        let threadIDs = Array(threadIDs)
        return try db.performSync { database in
            var conversations: [AgentThreadID: BotConversation] = [:]
            for start in stride(from: 0, to: threadIDs.count, by: Self.lookupBatchSize) {
                let batch = threadIDs[start..<min(start + Self.lookupBatchSize, threadIDs.count)]
                let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
                let statement = try database.prepare(
                    Self.conversationSelect + " WHERE linked_agent_thread_id IN (\(marks));"
                )
                defer { statement.reset() }
                for (index, threadID) in batch.enumerated() {
                    try statement.bind(Int32(index + 1), threadID.value.uuidString.lowercased())
                }
                while try statement.step() {
                    guard let conversation = try? decodeConversation(statement),
                          let threadID = conversation.linkedAgentThreadID,
                          conversations[threadID] == nil else { continue }
                    conversations[threadID] = conversation
                }
            }
            return conversations
        }
    }

    public func listConversations(attentionStates: [BotAttentionState]) throws -> [BotConversation] {
        guard !attentionStates.isEmpty else { return [] }
        return try db.performSync { database in
            let marks = Array(repeating: "?", count: attentionStates.count).joined(separator: ",")
            let statement = try database.prepare(
                """
                 SELECT * FROM (\(Self.conversationSelect))
                 WHERE group_id IS NULL AND attention_state IN (\(marks))
                 ORDER BY updated_at DESC;
                """
            )
            defer { statement.reset() }
            for (index, state) in attentionStates.enumerated() {
                try statement.bind(Int32(index + 1), state.rawValue)
            }
            var result: [BotConversation] = []
            while try statement.step() { result.append(try decodeConversation(statement)) }
            return result
        }
    }

    /// BotHome memory is global to the Bot. A workspace pin does not grant
    /// that memory; only an authorized general pin with memory access does.
    public func globalMemoryUnavailableReason(
        botID: BotID, threadID: AgentThreadID?, runID: AgentRunID? = nil
    ) throws -> String? {
        guard let threadID else { return nil }
        guard let conversation = try conversationLinked(to: threadID), conversation.botID == botID else {
            throw BotStoreError.invalidInput("The calling conversation does not belong to this Bot.")
        }
        guard let pin = try conversationContextPin(linkedTo: threadID) else { return nil }
        guard pin.botID == botID, pin.conversationID == conversation.id,
              try authorizes(hostID: pin.hostID, botID: botID, context: pin.context,
                             action: .read, policyRevision: pin.policyRevision),
              try runID.map({ try authorizesContextDelegation(hostID: pin.hostID, runID: $0, threadID: threadID) }) ?? true else {
            throw BotStoreError.invalidInput("The calling Bot conversation is no longer authorized.")
        }
        guard pin.context == .general else {
            return "Global Bot memory is unavailable in a workspace conversation; no workspace memory namespace is configured."
        }
        guard try authorizes(hostID: pin.hostID, botID: botID, context: pin.context,
                             action: .memory, policyRevision: pin.policyRevision) else {
            return "This general conversation requires a current memory grant to access global Bot memory."
        }
        return nil
    }

    public func searchLinkedMessages(
        botID: BotID, query: String, limit: Int, threadID: AgentThreadID? = nil
    ) throws -> [[String: String]] {
        let terms = BotSelfConfigService.recallTerms(query)
        guard !terms.isEmpty else { return [] }
        func pattern(_ text: String) -> String {
            "%" + text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_") + "%"
        }
        let matches = terms.map { _ in "m.content LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
        var values = [botID.value.uuidString.lowercased()]
        if let threadID { values.append(threadID.value.uuidString.lowercased()) }
        values += terms.map(pattern)
        values.append(pattern(query))
        return try db.performSync { database in
            let statement = try database.prepare("""
                SELECT m.thread_id, m.role, m.content, m.created_at, m.id, c.id
                FROM agent_messages m
                INNER JOIN bot_conversations c
                    ON c.linked_agent_thread_id = m.thread_id COLLATE NOCASE
                WHERE c.bot_id = ?
                  \(threadID == nil ? "" : "AND m.thread_id = ? COLLATE NOCASE")
                  AND \(matches)
                ORDER BY CASE WHEN m.content LIKE ? ESCAPE '\\' THEN 0 ELSE 1 END,
                         m.created_at DESC, m.id
                LIMIT ?;
                """)
            defer { statement.reset() }
            for (index, value) in values.enumerated() {
                try statement.bind(Int32(index + 1), value)
            }
            try statement.bind(Int32(values.count + 1), Int64(max(1, min(limit, 20))))
            var hits: [[String: String]] = []
            while try statement.step() {
                let content = statement.columnText(2) ?? ""
                hits.append([
                    "source": "conversation",
                    "source_kind": "conversation",
                    "bot_id": botID.value.uuidString.lowercased(),
                    "thread_id": statement.columnText(0) ?? "",
                    "message_id": statement.columnText(4) ?? "",
                    "conversation_id": statement.columnText(5) ?? "",
                    "role": statement.columnText(1) ?? "",
                    "snippet": BotSelfConfigService.snippet(in: content, matching: query),
                    "created_at": statement.columnText(3) ?? "",
                    "digest": RemoteCodeHostCatalog.bodyDigest(content),
                    "match_kind": content.localizedCaseInsensitiveContains(query) ? "exact_phrase" : "all_terms",
                ])
            }
            return hits
        }
    }

    /// Desk conversations of one bot. Group member conversations are hidden
    /// plumbing for group turns and are excluded unless `includeGroupMembers`
    /// (live-run discovery must still see a bot's group runs).
    public func listConversations(botID: BotID, includeGroupMembers: Bool = false) throws -> [BotConversation] {
        try db.performSync { database in
            let statement = try database.prepare(
                Self.conversationSelect + (includeGroupMembers
                    ? " WHERE bot_id = ? ORDER BY updated_at DESC;"
                    : " WHERE bot_id = ? AND group_id IS NULL ORDER BY updated_at DESC;")
            )
            defer { statement.reset() }
            try statement.bind(1, botID.value.uuidString.lowercased())
            var result: [BotConversation] = []
            while try statement.step() { result.append(try decodeConversation(statement)) }
            return result
        }
    }

    public func latestConversationUpdatedAt(botIDs: Set<BotID>) throws -> [BotID: Date] {
        guard !botIDs.isEmpty else { return [:] }
        let botIDs = Array(botIDs)
        return try db.performSync { database in
            var latest: [BotID: Date] = [:]
            for start in stride(from: 0, to: botIDs.count, by: Self.lookupBatchSize) {
                let batch = botIDs[start..<min(start + Self.lookupBatchSize, botIDs.count)]
                let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
                let statement = try database.prepare("""
                    SELECT bot_id, MAX(updated_at)
                    FROM bot_conversations
                    WHERE bot_id IN (\(marks)) AND group_id IS NULL
                    GROUP BY bot_id;
                    """)
                defer { statement.reset() }
                for (index, botID) in batch.enumerated() {
                    try statement.bind(Int32(index + 1), botID.value.uuidString.lowercased())
                }
                while try statement.step() {
                    guard let rawID = statement.columnText(0),
                          let id = UUID(uuidString: rawID),
                          let updatedAt = date(statement.columnText(1)) else { continue }
                    latest[BotID(id)] = updatedAt
                }
            }
            return latest
        }
    }

    /// Clears the bot's desk conversations. Group member conversations stay:
    /// their group participants still point at them.
    public func deleteConversations(botID: BotID) throws {
        let deskThreads: [AgentThreadID] = try db.performSync { database in
            let linked = try database.prepare("""
                SELECT linked_agent_thread_id FROM bot_conversations
                WHERE bot_id = ? AND group_id IS NULL AND linked_agent_thread_id IS NOT NULL;
                """)
            defer { linked.reset() }
            try linked.bind(1, botID.value.uuidString.lowercased())
            var threads: [AgentThreadID] = []
            while try linked.step() {
                if let raw = linked.columnText(0), let uuid = UUID(uuidString: raw) {
                    threads.append(AgentThreadID(uuid))
                }
            }
            linked.reset()
            let statement = try database.prepare("DELETE FROM bot_conversations WHERE bot_id = ? AND group_id IS NULL;")
            defer { statement.reset() }
            try statement.bind(1, botID.value.uuidString.lowercased())
            _ = try statement.step()
            return threads
        }
        forgetLinkedThreads(deskThreads)
    }

    public func upsertConversation(_ conversation: BotConversation) throws {
        try db.performSync { database in
            guard let bot = try loadBot(id: conversation.botID, database: database), bot.deletedAt == nil else {
                throw BotStoreError.notFound
            }
            let statement = try database.prepare("""
                INSERT INTO bot_conversations(
                    id, bot_id, title, pinned, hidden, unread, attention_state,
                    linked_agent_thread_id, created_at, updated_at, group_id
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title=excluded.title, pinned=excluded.pinned, hidden=excluded.hidden,
                    unread=excluded.unread, attention_state=excluded.attention_state,
                    linked_agent_thread_id=excluded.linked_agent_thread_id,
                    updated_at=excluded.updated_at;
                """)
            defer { statement.reset() }
            try statement.bind(1, conversation.id.value.uuidString.lowercased())
            try statement.bind(2, conversation.botID.value.uuidString.lowercased())
            try statement.bind(3, conversation.title)
            try statement.bind(4, conversation.pinned)
            try statement.bind(5, conversation.hidden)
            try statement.bind(6, conversation.unread)
            try statement.bind(7, conversation.attentionState.rawValue)
            try statement.bind(8, conversation.linkedAgentThreadID?.value.uuidString.lowercased())
            try statement.bind(9, string(conversation.createdAt))
            try statement.bind(10, string(conversation.updatedAt))
            try statement.bind(11, conversation.groupID?.value.uuidString.lowercased())
            _ = try statement.step()
        }
        rememberLinkedThread(conversation)
    }

    public func listMemory(botID: BotID, includeForgotten: Bool = false) throws -> [BotMemoryItem] {
        try db.performSync { database in
            var sql = Self.memorySelect + " WHERE i.bot_id = ?"
            if !includeForgotten { sql += " AND i.forgotten_at IS NULL" }
            sql += " ORDER BY i.updated_at DESC;"
            let statement = try database.prepare(sql)
            defer { statement.reset() }
            try statement.bind(1, botID.value.uuidString.lowercased())
            var result: [BotMemoryItem] = []
            while try statement.step() { result.append(try decodeMemory(statement)) }
            return result
        }
    }

    public func getMemory(id: BotMemoryItemID) throws -> BotMemoryItem? {
        try db.performSync { database in
            let statement = try database.prepare(Self.memorySelect + " WHERE i.id = ? LIMIT 1;")
            defer { statement.reset() }
            try statement.bind(1, id.value.uuidString.lowercased())
            return try statement.step() ? try decodeMemory(statement) : nil
        }
    }

    public func listMemoryRevisions(itemID: BotMemoryItemID) throws -> [BotMemoryItemRevision] {
        try db.performSync { database in
            let statement = try database.prepare("""
                SELECT id, item_id, bot_id, revision_number, content, provenance, trusted, source,
                       created_at, supersedes_revision_id
                FROM bot_memory_item_revisions
                WHERE item_id = ?
                ORDER BY revision_number ASC;
                """)
            defer { statement.reset() }
            try statement.bind(1, itemID.value.uuidString.lowercased())
            var result: [BotMemoryItemRevision] = []
            while try statement.step() { result.append(try decodeMemoryRevision(statement)) }
            return result
        }
    }

    public func putMemory(
        botID: BotID,
        content: String,
        provenance: String,
        trusted: Bool,
        source: String,
        expiresAt: Date? = nil,
        now: Date = Date()
    ) throws -> BotMemoryItem {
        try db.transaction {
            guard let bot = try loadBot(id: botID, database: db), bot.deletedAt == nil else {
                throw BotStoreError.notFound
            }
            let itemID = BotMemoryItemID()
            let revisionID = UUID()
            let insertItem = try db.prepare("""
                INSERT INTO bot_memory_items(
                    id, bot_id, current_revision_id, forgotten_at, expires_at, created_at, updated_at
                ) VALUES(?, ?, ?, NULL, ?, ?, ?);
                """)
            defer { insertItem.reset() }
            try insertItem.bind(1, itemID.value.uuidString.lowercased())
            try insertItem.bind(2, botID.value.uuidString.lowercased())
            try insertItem.bind(3, revisionID.uuidString.lowercased())
            try insertItem.bind(4, string(expiresAt))
            try insertItem.bind(5, string(now))
            try insertItem.bind(6, string(now))
            _ = try insertItem.step()
            try insertMemoryRevision(
                BotMemoryItemRevision(
                    id: revisionID,
                    itemID: itemID,
                    botID: botID,
                    revisionNumber: 1,
                    content: content,
                    provenance: provenance,
                    trusted: trusted,
                    source: source,
                    createdAt: now
                ),
                database: db
            )
            return BotMemoryItem(
                id: itemID,
                botID: botID,
                currentRevisionID: revisionID,
                content: content,
                provenance: provenance,
                trusted: trusted,
                source: source,
                expiresAt: expiresAt,
                createdAt: now,
                updatedAt: now
            )
        }
    }

    public func correctMemory(
        id: BotMemoryItemID,
        content: String,
        provenance: String? = nil,
        trusted: Bool? = nil,
        source: String? = nil,
        now: Date = Date()
    ) throws -> BotMemoryItem {
        try db.transaction {
            guard var item = try loadMemory(id: id, database: db) else { throw BotStoreError.notFound }
            if item.forgottenAt != nil { throw BotStoreError.invalidRow("forgotten memory cannot be rewritten") }
            let nextNumber = try nextMemoryRevisionNumber(itemID: id, database: db)
            let revisionID = UUID()
            try insertMemoryRevision(
                BotMemoryItemRevision(
                    id: revisionID,
                    itemID: id,
                    botID: item.botID,
                    revisionNumber: nextNumber,
                    content: content,
                    provenance: provenance ?? item.provenance,
                    trusted: trusted ?? item.trusted,
                    source: source ?? item.source,
                    createdAt: now,
                    supersedesRevisionID: item.currentRevisionID
                ),
                database: db
            )
            let update = try db.prepare("""
                UPDATE bot_memory_items
                SET current_revision_id = ?, updated_at = ?
                WHERE id = ?;
                """)
            defer { update.reset() }
            try update.bind(1, revisionID.uuidString.lowercased())
            try update.bind(2, string(now))
            try update.bind(3, id.value.uuidString.lowercased())
            _ = try update.step()
            item.currentRevisionID = revisionID
            item.content = content
            item.provenance = provenance ?? item.provenance
            item.trusted = trusted ?? item.trusted
            item.source = source ?? item.source
            item.updatedAt = now
            return item
        }
    }

    public func forgetMemory(id: BotMemoryItemID, now: Date = Date()) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                UPDATE bot_memory_items
                SET forgotten_at = COALESCE(forgotten_at, ?), updated_at = ?
                WHERE id = ?;
                """)
            defer { statement.reset() }
            try statement.bind(1, string(now))
            try statement.bind(2, string(now))
            try statement.bind(3, id.value.uuidString.lowercased())
            _ = try statement.step()
        }
    }

    public func listAttention(includeAcknowledged: Bool = false, conversationID: BotConversationID? = nil) throws -> [BotAttentionItem] {
        try db.performSync { database in
            var sql = Self.attentionSelect
            if !includeAcknowledged {
                sql += """
                     WHERE \(Self.openAttentionPredicate)
                       AND (
                           conversation_id IS NULL
                           OR EXISTS (
                               SELECT 1
                               FROM bot_conversations
                               WHERE bot_conversations.id = bot_attention_items.conversation_id
                                 AND bot_conversations.group_id IS NULL
                                 AND (
                                     bot_conversations.linked_agent_thread_id IS NULL
                                     OR (
                                         EXISTS (
                                             SELECT 1
                                             FROM agent_threads
                                             WHERE agent_threads.id = bot_conversations.linked_agent_thread_id COLLATE NOCASE
                                         )
                                         AND (
                                             EXISTS (
                                                 SELECT 1 FROM agent_messages
                                                 WHERE agent_messages.thread_id = bot_conversations.linked_agent_thread_id COLLATE NOCASE
                                             )
                                             OR EXISTS (
                                                 SELECT 1 FROM agent_runs
                                                 WHERE agent_runs.thread_id = bot_conversations.linked_agent_thread_id COLLATE NOCASE
                                             )
                                         )
                                     )
                                 )
                           )
                       )
                    """
            }
            if conversationID != nil {
                sql += includeAcknowledged ? " WHERE conversation_id = ?" : " AND conversation_id = ?"
            }
            sql += " ORDER BY created_at DESC;"
            let statement = try database.prepare(sql)
            defer { statement.reset() }
            if let conversationID { try statement.bind(1, conversationID.value.uuidString.lowercased()) }
            var result: [BotAttentionItem] = []
            while try statement.step() { result.append(try decodeAttention(statement)) }
            return result
        }
    }

    /// A new accepted message answers the previous question; a newly admitted
    /// run retries the previous failure. Keep these receipts, but resolve them
    /// before the new turn can create another request (including in the same second).
    func resolveAttention(threadID: AgentThreadID, kinds: [BotAttentionItemKind], at date: Date) throws {
        let statement = try db.prepare("""
            UPDATE bot_attention_items SET acknowledged_at = ?
            WHERE acknowledged_at IS NULL
              AND kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))
              AND julianday(created_at) <= julianday(?)
              AND conversation_id IN (
                  SELECT id FROM bot_conversations
                  WHERE linked_agent_thread_id = ? COLLATE NOCASE AND group_id IS NULL
              );
            """)
        defer { statement.reset() }
        try statement.bind(1, string(date))
        for (index, kind) in kinds.enumerated() { try statement.bind(Int32(index + 2), kind.rawValue) }
        try statement.bind(Int32(kinds.count + 2), isoFractional.string(from: date))
        try statement.bind(Int32(kinds.count + 3), threadID.description)
        _ = try statement.step()
    }

    public func upsertAttention(_ item: BotAttentionItem) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                INSERT INTO bot_attention_items(
                    id, bot_id, conversation_id, kind, title, detail, created_at, acknowledged_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    kind=excluded.kind, title=excluded.title, detail=excluded.detail,
                    conversation_id=excluded.conversation_id, acknowledged_at=excluded.acknowledged_at;
                """)
            defer { statement.reset() }
            try statement.bind(1, item.id.value.uuidString.lowercased())
            try statement.bind(2, item.botID.value.uuidString.lowercased())
            try statement.bind(3, item.conversationID?.value.uuidString.lowercased())
            try statement.bind(4, item.kind.rawValue)
            try statement.bind(5, item.title)
            try statement.bind(6, item.detail)
            try statement.bind(7, string(item.createdAt))
            try statement.bind(8, string(item.acknowledgedAt))
            _ = try statement.step()
        }
    }

    public func acknowledgeAttention(id: BotAttentionItemID, now: Date = Date()) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                UPDATE bot_attention_items
                SET acknowledged_at = COALESCE(acknowledged_at, ?)
                WHERE id = ?;
                """)
            defer { statement.reset() }
            try statement.bind(1, string(now))
            try statement.bind(2, id.value.uuidString.lowercased())
            _ = try statement.step()
        }
    }

    /// Batch acknowledgment in one transaction; a nil date reopens the items.
    /// Returns only ids that still exist.
    public func setAttentionAcknowledged(ids: [BotAttentionItemID], at date: Date?) throws -> [BotAttentionItemID] {
        guard !ids.isEmpty else { return [] }
        return try db.performSync { database in
            try database.transaction {
                let exists = try database.prepare("SELECT 1 FROM bot_attention_items WHERE id = ?;")
                let statement = try database.prepare("""
                    UPDATE bot_attention_items
                    SET acknowledged_at = CASE WHEN ? IS NULL THEN NULL ELSE COALESCE(acknowledged_at, ?) END
                    WHERE id = ?;
                    """)
                var updated: [BotAttentionItemID] = []
                for id in ids {
                    let key = id.value.uuidString.lowercased()
                    try exists.bind(1, key)
                    let found = try exists.step()
                    exists.reset()
                    guard found else { continue }
                    try statement.bind(1, string(date))
                    try statement.bind(2, string(date))
                    try statement.bind(3, key)
                    _ = try statement.step()
                    statement.reset()
                    updated.append(id)
                }
                return updated
            }
        }
    }

    /// Causal proof from `TerminalTransitionLedger` for the one-way legacy
    /// `Run cancelled` repair. Missing or mismatched proof preserves the row.
    public struct LegacyUserStopLedgerProof: Equatable, Sendable {
        public var runId: String
        public var threadId: String
        public var eventTime: Date
        public var reason: String

        public init(runId: String, threadId: String, eventTime: Date, reason: String) {
            self.runId = runId
            self.threadId = threadId
            self.eventTime = eventTime
            self.reason = reason
        }
    }

    /// Exact pre-column signature manufactured for every cancelled Bot turn.
    public enum LegacyUserStopAttentionSignature {
        public static let kind = BotAttentionItemKind.question
        public static let title = "Run cancelled"
        public static let detail = "The supervised turn ended without a clean completion."
        public static let terminalReason = "userStop"
    }

    #if DEBUG
    /// Test seam: throw after acknowledging matching rows and before conversation
    /// reset so a rolled-back transaction cannot split row vs conversation.
    public var legacyRepairFaultAfterAcknowledgeForTesting = false
    #endif

    /// Forward-only repair of proven false legacy user-Stop attention artifacts.
    ///
    /// Reads causal candidates from the caller (TerminalTransitionLedger), then
    /// revalidates every SQLite predicate inside one transaction: exact old
    /// kind/title/detail, linked conversation, case-normalized run/thread,
    /// ledger `reason=userStop` with matching event/finish/attention time,
    /// cancelled provider session with the same `last_run_id`, no later run,
    /// and no pending provider callback. Acknowledges duplicate matching rows
    /// and resets the conversation only when no other actionable row remains.
    /// Missing ledger or any mismatch preserves messages, runs, and rows.
    /// Intentionally does not delete data and cannot un-acknowledge a row.
    @discardableResult
    public func repairLegacyUserStopAttention(
        proofs: [LegacyUserStopLedgerProof],
        now: Date = Date()
    ) throws -> Int {
        var seen = Set<String>()
        let userStopProofs = proofs.filter { proof in
            guard proof.reason == "userStop" else { return false }
            let key = proof.runId.lowercased() + "\0" + proof.threadId.lowercased()
            return seen.insert(key).inserted
        }
        guard !userStopProofs.isEmpty else { return 0 }
        return try db.transaction {
            var acknowledged = 0
            var conversationsToReset: Set<String> = []
            for proof in userStopProofs {
                let matched = try matchingLegacyUserStopAttentionIDs(proof: proof, database: db)
                guard !matched.itemIDs.isEmpty else { continue }
                for itemID in matched.itemIDs {
                    let statement = try db.prepare("""
                        UPDATE bot_attention_items
                        SET acknowledged_at = COALESCE(acknowledged_at, ?)
                        WHERE id = ?;
                        """)
                    defer { statement.reset() }
                    try statement.bind(1, string(now))
                    try statement.bind(2, itemID)
                    _ = try statement.step()
                    acknowledged += 1
                }
                conversationsToReset.formUnion(matched.conversationIDs)
            }
            #if DEBUG
            if legacyRepairFaultAfterAcknowledgeForTesting {
                throw BotStoreError.invalidRow("injected legacy repair fault")
            }
            #endif
            for conversationID in conversationsToReset {
                if try conversationHasOtherActionableAttention(
                    conversationID: conversationID,
                    database: db
                ) {
                    continue
                }
                let statement = try db.prepare("""
                    UPDATE bot_conversations
                    SET attention_state = 'none', unread = 0, updated_at = ?
                    WHERE id = ?;
                    """)
                defer { statement.reset() }
                try statement.bind(1, string(now))
                try statement.bind(2, conversationID)
                _ = try statement.step()
            }
            return acknowledged
        }
    }

    private struct LegacyUserStopMatch {
        var itemIDs: [String]
        var conversationIDs: Set<String>
    }

    private func matchingLegacyUserStopAttentionIDs(
        proof: LegacyUserStopLedgerProof,
        database: SQLiteDB
    ) throws -> LegacyUserStopMatch {
        let runKey = proof.runId.lowercased()
        let threadKey = proof.threadId.lowercased()
        let statement = try database.prepare("""
            SELECT id, conversation_id, created_at
            FROM bot_attention_items
            WHERE acknowledged_at IS NULL
              AND kind = ?
              AND title = ?
              AND detail = ?;
            """)
        defer { statement.reset() }
        try statement.bind(1, LegacyUserStopAttentionSignature.kind.rawValue)
        try statement.bind(2, LegacyUserStopAttentionSignature.title)
        try statement.bind(3, LegacyUserStopAttentionSignature.detail)
        var candidates: [(id: String, conversationID: String, createdAt: String)] = []
        while try statement.step() {
            guard let id = statement.columnText(0),
                  let conversationID = statement.columnText(1),
                  let createdAt = statement.columnText(2) else { continue }
            candidates.append((id, conversationID, createdAt))
        }

        var matchedIDs: [String] = []
        var matchedConversations: Set<String> = []
        for candidate in candidates {
            guard let created = date(candidate.createdAt),
                  Self.legacyRepairTimesMatch(created, proof.eventTime) else { continue }
            let conversation = try database.prepare("""
                SELECT linked_agent_thread_id
                FROM bot_conversations
                WHERE id = ?
                LIMIT 1;
                """)
            defer { conversation.reset() }
            try conversation.bind(1, candidate.conversationID)
            guard try conversation.step(),
                  let linked = conversation.columnText(0),
                  linked.lowercased() == threadKey else { continue }

            let run = try database.prepare("""
                SELECT id, thread_id, status, finished_at, started_at, terminal_reason
                FROM agent_runs
                WHERE id = ? COLLATE NOCASE
                LIMIT 1;
                """)
            defer { run.reset() }
            try run.bind(1, proof.runId)
            guard try run.step(),
                  (run.columnText(0) ?? "").lowercased() == runKey,
                  (run.columnText(1) ?? "").lowercased() == threadKey,
                  run.columnText(2) == AgentRunStatus.cancelled.rawValue,
                  let finishedRaw = run.columnText(3),
                  let finishedAt = iso.date(from: finishedRaw) ?? date(finishedRaw),
                  Self.legacyRepairTimesMatch(finishedAt, proof.eventTime) else { continue }
            let terminalReason = run.columnText(5)
            guard terminalReason == nil
                    || terminalReason == LegacyUserStopAttentionSignature.terminalReason else { continue }

            let later = try database.prepare("""
                SELECT 1
                FROM agent_runs
                WHERE thread_id = ? COLLATE NOCASE
                  AND id != ? COLLATE NOCASE
                  AND started_at >= ?
                LIMIT 1;
                """)
            defer { later.reset() }
            try later.bind(1, proof.threadId)
            try later.bind(2, proof.runId)
            try later.bind(3, finishedRaw)
            if try later.step() { continue }

            let session = try database.prepare("""
                SELECT status, last_run_id
                FROM provider_session_runtime
                WHERE thread_id = ? COLLATE NOCASE
                LIMIT 1;
                """)
            defer { session.reset() }
            try session.bind(1, proof.threadId)
            guard try session.step(),
                  session.columnText(0) == AgentRunStatus.cancelled.rawValue,
                  (session.columnText(1) ?? "").lowercased() == runKey else { continue }

            let callback = try database.prepare("""
                SELECT 1
                FROM provider_pending_callbacks
                WHERE thread_id = ? COLLATE NOCASE
                  AND state = ?
                LIMIT 1;
                """)
            defer { callback.reset() }
            try callback.bind(1, proof.threadId)
            try callback.bind(2, AssistantRequestState.pending.rawValue)
            if try callback.step() { continue }

            if terminalReason == nil {
                // v76 and older runs acquire the nullable v77 column as NULL.
                // Establish the cause only after every ledger/run/session/
                // callback predicate above proves this exact legacy user Stop.
                let backfill = try database.prepare("""
                    UPDATE agent_runs
                    SET terminal_reason = ?
                    WHERE id = ? COLLATE NOCASE
                      AND terminal_reason IS NULL;
                    """)
                defer { backfill.reset() }
                try backfill.bind(1, LegacyUserStopAttentionSignature.terminalReason)
                try backfill.bind(2, proof.runId)
                _ = try backfill.step()
            }

            matchedIDs.append(candidate.id)
            matchedConversations.insert(candidate.conversationID)
        }
        return LegacyUserStopMatch(itemIDs: matchedIDs, conversationIDs: matchedConversations)
    }

    private func conversationHasOtherActionableAttention(
        conversationID: String,
        database: SQLiteDB
    ) throws -> Bool {
        let statement = try database.prepare("""
            SELECT 1
            FROM bot_attention_items
            WHERE conversation_id = ?
              AND acknowledged_at IS NULL
            LIMIT 1;
            """)
        defer { statement.reset() }
        try statement.bind(1, conversationID)
        return try statement.step()
    }

    private static func legacyRepairTimesMatch(_ lhs: Date, _ rhs: Date) -> Bool {
        Int(lhs.timeIntervalSince1970) == Int(rhs.timeIntervalSince1970)
    }

    public func listRoutines(botID: BotID) throws -> [BotRoutine] {
        try db.performSync { database in
            try loadRoutines(botID: botID, database: database)
        }
    }

    /// Every enabled routine of a bot that is not deleted, in one query: the
    /// routine scheduler reads this every tick instead of one read per bot.
    public func listEnabledRoutines() throws -> [BotRoutine] {
        try db.performSync { database in
            let statement = try database.prepare("""
                SELECT d.id, d.bot_id, d.name, d.prompt, d.schedule_note, d.created_at, d.updated_at, d.schedule_spec_json,
                       a.routine_id, a.bot_id, a.is_enabled, a.last_test_run_requested_at, a.updated_at
                FROM bot_routine_definitions d
                JOIN bot_routine_activations a ON a.routine_id = d.id
                JOIN bots b ON b.id = d.bot_id
                WHERE a.is_enabled = 1 AND b.deleted_at IS NULL
                ORDER BY d.updated_at DESC;
                """)
            defer { statement.reset() }
            var result: [BotRoutine] = []
            while try statement.step() {
                let definition = try decodeRoutineDefinition(statement)
                let activation = try decodeActivation(statement, offset: 8)
                result.append(BotRoutine(definition: definition, activation: activation))
            }
            return result
        }
    }

    public func saveRoutine(_ definition: BotRoutineDefinition, enabled: Bool? = nil, now: Date = Date()) throws {
        if let destination = definition.scheduleSpec?.executionDestination {
            try validateExecutionDestination(destination, botID: definition.botID)
        }
        try db.transaction {
            guard let bot = try loadBot(id: definition.botID, database: db), bot.deletedAt == nil else {
                throw BotStoreError.notFound
            }
            try insertRoutine(definition, database: db)
            if try loadActivation(routineID: definition.id, database: db) == nil {
                try upsertActivation(
                    BotRoutineActivation(
                        routineID: definition.id,
                        botID: definition.botID,
                        isEnabled: false,
                        updatedAt: now
                    ),
                    database: db
                )
            }
            if let enabled {
                try setRoutineEnabled(id: definition.id, botID: definition.botID, enabled: enabled, now: now)
            }
        }
    }

    public func setRoutineEnabled(id: BotRoutineID, enabled: Bool, now: Date = Date()) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                UPDATE bot_routine_activations
                SET is_enabled = ?, updated_at = ?
                WHERE routine_id = ?;
                """)
            defer { statement.reset() }
            try statement.bind(1, enabled)
            try statement.bind(2, string(now))
            try statement.bind(3, id.value.uuidString.lowercased())
            _ = try statement.step()
        }
    }

    public func setRoutineEnabled(
        id: BotRoutineID,
        botID: BotID,
        enabled: Bool,
        now: Date = Date()
    ) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                UPDATE bot_routine_activations
                SET is_enabled = ?, updated_at = ?
                WHERE routine_id = ? AND bot_id = ?;
                """)
            defer { statement.reset() }
            try statement.bind(1, enabled)
            try statement.bind(2, string(now))
            try statement.bind(3, id.value.uuidString.lowercased())
            try statement.bind(4, botID.value.uuidString.lowercased())
            _ = try statement.step()
            let changes = try database.prepare("SELECT changes();")
            defer { changes.reset() }
            guard try changes.step(), changes.columnInt64(0) == 1 else {
                throw BotStoreError.notFound
            }
        }
    }

    public func deleteRoutine(id: BotRoutineID) throws {
        try db.transaction {
            let key = id.value.uuidString.lowercased()
            let activation = try db.prepare("DELETE FROM bot_routine_activations WHERE routine_id = ?;")
            defer { activation.reset() }
            try activation.bind(1, key)
            _ = try activation.step()
            let definition = try db.prepare("DELETE FROM bot_routine_definitions WHERE id = ?;")
            defer { definition.reset() }
            try definition.bind(1, key)
            _ = try definition.step()
        }
    }

    public func deleteRoutine(id: BotRoutineID, botID: BotID) throws {
        try db.transaction {
            let key = id.value.uuidString.lowercased()
            let botKey = botID.value.uuidString.lowercased()
            let activation = try db.prepare(
                "DELETE FROM bot_routine_activations WHERE routine_id = ? AND bot_id = ?;"
            )
            defer { activation.reset() }
            try activation.bind(1, key)
            try activation.bind(2, botKey)
            _ = try activation.step()
            let definition = try db.prepare(
                "DELETE FROM bot_routine_definitions WHERE id = ? AND bot_id = ?;"
            )
            defer { definition.reset() }
            try definition.bind(1, key)
            try definition.bind(2, botKey)
            _ = try definition.step()
            let changes = try db.prepare("SELECT changes();")
            defer { changes.reset() }
            guard try changes.step(), changes.columnInt64(0) == 1 else {
                throw BotStoreError.notFound
            }
        }
    }

    public func requestRoutineTestRun(id: BotRoutineID, now: Date = Date()) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                UPDATE bot_routine_activations
                SET last_test_run_requested_at = ?, updated_at = ?
                WHERE routine_id = ?;
                """)
            defer { statement.reset() }
            try statement.bind(1, string(now))
            try statement.bind(2, string(now))
            try statement.bind(3, id.value.uuidString.lowercased())
            _ = try statement.step()
        }
    }

    public func listSkillBindings(botID: BotID) throws -> [BotSkillBinding] {
        try db.performSync { database in
            try loadSkillBindings(botID: botID, database: database)
        }
    }

    public func insertContextReceipt(_ receipt: ContextAssemblyReceipt) throws {
        try db.performSync { database in
            let data = try encoder.encode(receipt)
            guard let json = String(data: data, encoding: .utf8) else {
                throw BotStoreError.invalidRow("context receipt is not UTF-8")
            }
            let statement = try database.prepare("""
                INSERT INTO bot_context_receipts(
                    id, bot_id, conversation_id, run_id, revision_id, payload_digest,
                    receipt_json, assembled_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    run_id=excluded.run_id,
                    receipt_json=excluded.receipt_json;
                """)
            defer { statement.reset() }
            try statement.bind(1, receipt.id.uuidString.lowercased())
            try statement.bind(2, receipt.botID.value.uuidString.lowercased())
            try statement.bind(3, receipt.conversationID?.value.uuidString.lowercased())
            try statement.bind(4, receipt.runID?.value.uuidString.lowercased())
            try statement.bind(5, receipt.revisionID.value.uuidString.lowercased())
            try statement.bind(6, receipt.payloadDigest)
            try statement.bind(7, json)
            try statement.bind(8, string(receipt.assembledAt))
            _ = try statement.step()
        }
    }

    public func latestContextReceipt(
        botID: BotID,
        conversationID: BotConversationID? = nil
    ) throws -> ContextAssemblyReceipt? {
        try db.performSync { database in
            let sql: String
            if conversationID != nil {
                sql = """
                    SELECT receipt_json FROM bot_context_receipts
                    WHERE bot_id = ? AND conversation_id = ?
                    ORDER BY assembled_at DESC LIMIT 1;
                    """
            } else {
                sql = """
                    SELECT receipt_json FROM bot_context_receipts
                    WHERE bot_id = ?
                    ORDER BY assembled_at DESC LIMIT 1;
                    """
            }
            let statement = try database.prepare(sql)
            defer { statement.reset() }
            try statement.bind(1, botID.value.uuidString.lowercased())
            if let conversationID {
                try statement.bind(2, conversationID.value.uuidString.lowercased())
            }
            guard try statement.step(), let json = statement.columnText(0),
                  let data = json.data(using: .utf8) else { return nil }
            return try decoder.decode(ContextAssemblyReceipt.self, from: data)
        }
    }

    public func setSkillBinding(_ binding: BotSkillBinding) throws {
        let skillID = binding.skillID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !skillID.isEmpty, !skillID.contains("/") else {
            throw BotStoreError.invalidRow("skill id must be a catalog id, not a path")
        }
        try db.transaction {
            guard let bot = try loadBot(id: binding.botID, database: db), bot.deletedAt == nil else {
                throw BotStoreError.notFound
            }
            try upsertSkillBinding(
                BotSkillBinding(
                    botID: binding.botID,
                    skillID: skillID,
                    enabled: binding.enabled,
                    digest: binding.digest,
                    updatedAt: binding.updatedAt
                ),
                database: db
            )
        }
    }

    public func removeSkillBinding(botID: BotID, skillID: String) throws {
        let skillID = skillID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !skillID.isEmpty, !skillID.contains("/") else {
            throw BotStoreError.invalidRow("skill id must be a catalog id, not a path")
        }
        try db.transaction {
            guard let bot = try loadBot(id: botID, database: db), bot.deletedAt == nil else {
                throw BotStoreError.notFound
            }
            let statement = try db.prepare(
                "DELETE FROM bot_skill_bindings WHERE bot_id = ? AND skill_id = ?;"
            )
            defer { statement.reset() }
            try statement.bind(1, botID.value.uuidString.lowercased())
            try statement.bind(2, skillID)
            _ = try statement.step()
        }
    }

    public func listQueuedFollowUps(botID: BotID) throws -> [BotQueuedFollowUpRecord] {
        try db.performSync { database in
            try self.loadQueuedFollowUps(botID: botID, database: database)
        }
    }

    public func listAllQueuedFollowUps() throws -> [BotQueuedFollowUpRecord] {
        try db.performSync { database in
            let statement = try database.prepare(
                """
                SELECT id, bot_id, conversation_id, text, payload_json, sort_order, created_at
                FROM bot_queued_follow_ups
                ORDER BY bot_id ASC, sort_order ASC;
                """
            )
            defer { statement.reset() }
            var rows: [BotQueuedFollowUpRecord] = []
            while try statement.step() {
                rows.append(try decodeQueuedFollowUp(statement))
            }
            return rows
        }
    }

    public func enqueueQueuedFollowUp(_ record: BotQueuedFollowUpRecord) throws -> BotQueuedFollowUpRecord {
        try db.transaction {
            guard let bot = try loadBot(id: record.botID, database: db), bot.deletedAt == nil else {
                throw BotStoreError.notFound
            }
            let nextOrder = try nextQueuedFollowUpSortOrder(botID: record.botID, database: db)
            let stored = BotQueuedFollowUpRecord(
                id: record.id,
                botID: record.botID,
                conversationID: record.conversationID,
                text: record.text,
                payloadJSON: record.payloadJSON.isEmpty ? "{}" : record.payloadJSON,
                sortOrder: nextOrder,
                createdAt: record.createdAt
            )
            try insertQueuedFollowUp(stored, database: db)
            return stored
        }
    }

    public func replaceQueuedFollowUps(botID: BotID, items: [BotQueuedFollowUpRecord]) throws {
        try db.transaction {
            try deleteQueuedFollowUpsLocked(botID: botID, database: db)
            for (index, item) in items.enumerated() {
                try insertQueuedFollowUp(
                    BotQueuedFollowUpRecord(
                        id: item.id,
                        botID: botID,
                        conversationID: item.conversationID,
                        text: item.text,
                        payloadJSON: item.payloadJSON.isEmpty ? "{}" : item.payloadJSON,
                        sortOrder: index,
                        createdAt: item.createdAt
                    ),
                    database: db
                )
            }
        }
    }

    public func removeQueuedFollowUp(botID: BotID, id: String) throws {
        try db.performSync { database in
            let statement = try database.prepare(
                "DELETE FROM bot_queued_follow_ups WHERE bot_id = ? AND id = ?;"
            )
            defer { statement.reset() }
            try statement.bind(1, botID.value.uuidString.lowercased())
            try statement.bind(2, id)
            _ = try statement.step()
        }
    }

    /// A provider acknowledgement may remove only the exact intent it accepted.
    public func acknowledgeQueuedFollowUp(_ expected: BotQueuedFollowUpRecord) throws -> Bool {
        try db.transaction {
            let statement = try db.prepare("DELETE FROM bot_queued_follow_ups WHERE bot_id=? AND id=? AND conversation_id IS ? AND text=? AND payload_json=?;")
            defer { statement.reset() }
            try statement.bind(1, expected.botID.value.uuidString.lowercased())
            try statement.bind(2, expected.id)
            try statement.bind(3, expected.conversationID)
            try statement.bind(4, expected.text)
            try statement.bind(5, expected.payloadJSON)
            _ = try statement.step()
            let changes = try db.prepare("SELECT changes();")
            defer { changes.reset() }
            return try changes.step() && changes.columnInt64(0) == 1
        }
    }

    public func dequeueQueuedFollowUp(botID: BotID) throws -> BotQueuedFollowUpRecord? {
        try db.transaction {
            let statement = try db.prepare(
                """
                SELECT id, bot_id, conversation_id, text, payload_json, sort_order, created_at
                FROM bot_queued_follow_ups
                WHERE bot_id = ?
                ORDER BY sort_order ASC
                LIMIT 1;
                """
            )
            defer { statement.reset() }
            try statement.bind(1, botID.value.uuidString.lowercased())
            guard try statement.step() else { return nil }
            let record = try decodeQueuedFollowUp(statement)
            guard try !HostDatabaseRestore.requiresQueueReview(kind: .bot, id: record.id, db: db) else { return nil }
            statement.reset()
            try removeQueuedFollowUpLocked(botID: botID, id: record.id, database: db)
            return record
        }
    }

    public func deleteQueuedFollowUps(botID: BotID) throws {
        try db.performSync { database in
            try deleteQueuedFollowUpsLocked(botID: botID, database: database)
        }
    }

    // MARK: - Internals

    private func publishLocked(
        bot: BotDefinition,
        expectedCurrentRevisionID: BotRevisionID?,
        draft: BotRevisionDraft,
        avatarSymbol: String,
        notificationsEnabled: Bool,
        now: Date,
        database: SQLiteDB
    ) throws -> BotRevision {
        if bot.currentRevisionID != expectedCurrentRevisionID {
            throw BotPublishError.revisionConflict
        }
        let previous = try bot.currentRevisionID.flatMap { try loadRevision(id: $0, database: database) }
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw BotPublishError.invalidRevision }
        let nextNumber = try nextRevisionNumber(botID: bot.id, database: database)
        let revisionID = BotRevisionID()
        let normalized = BotRevisionDraft(
            name: trimmedName,
            title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: draft.description.trimmingCharacters(in: .whitespacesAndNewlines),
            soul: draft.soul,
            permissionMode: draft.permissionMode,
            desktopKind: draft.desktopKind
        )
        let revision = makeRevision(
            id: revisionID,
            botID: bot.id,
            revisionNumber: nextNumber,
            draft: normalized,
            publishedAt: now,
            supersedes: bot.currentRevisionID
        )
        try insertRevision(revision, database: database)
        try setCurrentRevision(
            botID: bot.id,
            revisionID: revisionID,
            name: normalized.name,
            title: normalized.title,
            description: normalized.description,
            avatarSymbol: avatarSymbol,
            notificationsEnabled: notificationsEnabled,
            updatedAt: now,
            database: database
        )
        if previous.map({ BotExecutionDefault.target(for: $0) }) != BotExecutionDefault.target(for: revision) {
            try writeExecutionDestination(revision.desktopKind == .dockerDesktop ? .ownVM : .mac, botID: bot.id)
        }
        return revision
    }

    private func makeRevision(
        id: BotRevisionID,
        botID: BotID,
        revisionNumber: Int,
        draft: BotRevisionDraft,
        publishedAt: Date,
        supersedes: BotRevisionID?
    ) -> BotRevision {
        BotRevision(
            id: id,
            botID: botID,
            revisionNumber: revisionNumber,
            name: draft.name,
            title: draft.title,
            description: draft.description,
            soul: draft.soul,
            permissionMode: draft.permissionMode,
            desktopKind: draft.desktopKind,
            digest: BotRevision.digest(botID: botID, draft: draft),
            publishedAt: publishedAt,
            supersedesRevisionID: supersedes
        )
    }

    private func resolveHandle(_ explicit: String?, fallback: String) throws -> String {
        if let explicit {
            guard let normalized = BotHandle.normalize(explicit) else { throw BotPublishError.handleEmpty }
            return normalized
        }
        guard let derived = BotHandle.derive(from: fallback) else { throw BotPublishError.handleEmpty }
        return derived
    }

    private func assertLiveCapacity(database: SQLiteDB, additional: Int) throws {
        let statement = try database.prepare("SELECT COUNT(*) FROM bots WHERE deleted_at IS NULL;")
        defer { statement.reset() }
        guard try statement.step() else { throw BotStoreError.invalidRow("live bot count") }
        if Int(statement.columnInt64(0)) + additional > BotDefinition.liveAccountCap {
            throw BotPublishError.accountCap
        }
    }

    private func assertHandleAvailable(
        _ handle: String,
        excluding current: String? = nil,
        database: SQLiteDB
    ) throws {
        if current == handle { return }
        if try handleIsTaken(handle, database: database) { throw BotPublishError.handleConflict }
    }

    private func handleIsTaken(_ handle: String, database: SQLiteDB) throws -> Bool {
        let live = try database.prepare("SELECT 1 FROM bot_handles WHERE handle = ? LIMIT 1;")
        defer { live.reset() }
        try live.bind(1, handle)
        if try live.step() { return true }
        let tombstone = try database.prepare("SELECT 1 FROM bot_handle_tombstones WHERE handle = ? LIMIT 1;")
        defer { tombstone.reset() }
        try tombstone.bind(1, handle)
        return try tombstone.step()
    }

    private func allocateUniqueHandle(stem: String, database: SQLiteDB) throws -> String {
        let base = BotHandle.derive(from: stem) ?? "bot"
        if try !handleIsTaken(base, database: database) { return base }
        for index in 2...999 {
            let suffix = "-\(index)"
            let prefix = String(base.prefix(BotHandle.maxLength - suffix.count))
            let candidate = prefix + suffix
            if try !handleIsTaken(candidate, database: database) { return candidate }
        }
        throw BotPublishError.handleConflict
    }

    private func insertBot(_ bot: BotDefinition, currentRevisionID: BotRevisionID?, database: SQLiteDB) throws {
        let statement = try database.prepare("""
            INSERT INTO bots(
                id, handle, name, title, description, avatar_symbol, pinned, hidden,
                current_revision_id, directory_epoch, notifications_enabled,
                created_at, updated_at, deleted_at, workspace_id,
                reply_verbosity, caveman_enabled
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        defer { statement.reset() }
        try statement.bind(1, bot.id.value.uuidString.lowercased())
        try statement.bind(2, bot.handle)
        try statement.bind(3, bot.name)
        try statement.bind(4, bot.title)
        try statement.bind(5, bot.description)
        try statement.bind(6, bot.avatarSymbol)
        try statement.bind(7, bot.pinned)
        try statement.bind(8, bot.hidden)
        try statement.bind(9, currentRevisionID?.value.uuidString.lowercased())
        try statement.bind(10, bot.directoryEpoch)
        try statement.bind(11, bot.notificationsEnabled)
        try statement.bind(12, string(bot.createdAt))
        try statement.bind(13, string(bot.updatedAt))
        try statement.bind(14, string(bot.deletedAt))
        try statement.bind(15, bot.workspaceID?.value.uuidString.lowercased())
        try statement.bind(16, bot.verbosity.rawValue)
        try statement.bind(17, bot.cavemanEnabled)
        _ = try statement.step()
    }

    private func insertRevision(_ revision: BotRevision, database: SQLiteDB) throws {
        let routes = try encodeRoutes(Self.legacyCompatibleRouteSetColumnValue)
        let statement = try database.prepare("""
            INSERT INTO bot_revisions(
                id, bot_id, revision_number, name, title, description, soul, provider,
                provider_instance_id, model, reasoning_effort, compatible_route_set_json,
                permission_mode, desktop_kind, digest, published_at, supersedes_revision_id
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        defer { statement.reset() }
        try statement.bind(1, revision.id.value.uuidString.lowercased())
        try statement.bind(2, revision.botID.value.uuidString.lowercased())
        try statement.bind(3, revision.revisionNumber)
        try statement.bind(4, revision.name)
        try statement.bind(5, revision.title)
        try statement.bind(6, revision.description)
        try statement.bind(7, revision.soul)
        try statement.bind(8, Self.legacyProviderColumnValue.rawValue)
        try statement.bind(9, Self.legacyProviderInstanceColumnValue)
        try statement.bind(10, Self.legacyModelColumnValue)
        try statement.bind(11, Self.legacyReasoningEffortColumnValue.rawValue)
        try statement.bind(12, routes)
        try statement.bind(13, revision.permissionMode.rawValue)
        try statement.bind(14, revision.desktopKind.rawValue)
        try statement.bind(15, revision.digest)
        try statement.bind(16, string(revision.publishedAt))
        try statement.bind(17, revision.supersedesRevisionID?.value.uuidString.lowercased())
        _ = try statement.step()
    }

    private func setCurrentRevision(
        botID: BotID,
        revisionID: BotRevisionID,
        name: String,
        title: String,
        description: String,
        avatarSymbol: String,
        notificationsEnabled: Bool,
        updatedAt: Date,
        database: SQLiteDB
    ) throws {
        let statement = try database.prepare("""
            UPDATE bots
            SET current_revision_id = ?, name = ?, title = ?, description = ?,
                avatar_symbol = ?, notifications_enabled = ?, updated_at = ?
            WHERE id = ?;
            """)
        defer { statement.reset() }
        try statement.bind(1, revisionID.value.uuidString.lowercased())
        try statement.bind(2, name)
        try statement.bind(3, title)
        try statement.bind(4, description)
        try statement.bind(5, avatarSymbol)
        try statement.bind(6, notificationsEnabled)
        try statement.bind(7, string(updatedAt))
        try statement.bind(8, botID.value.uuidString.lowercased())
        _ = try statement.step()
    }

    private func insertLiveHandle(_ handle: String, botID: BotID, at date: Date, database: SQLiteDB) throws {
        let statement = try database.prepare(
            "INSERT INTO bot_handles(handle, bot_id, created_at) VALUES(?, ?, ?);"
        )
        defer { statement.reset() }
        try statement.bind(1, handle)
        try statement.bind(2, botID.value.uuidString.lowercased())
        try statement.bind(3, string(date))
        _ = try statement.step()
    }

    private func insertRoutine(_ definition: BotRoutineDefinition, database: SQLiteDB) throws {
        let statement = try database.prepare("""
            INSERT INTO bot_routine_definitions(
                id, bot_id, name, prompt, schedule_note, created_at, updated_at, schedule_spec_json
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name=excluded.name, prompt=excluded.prompt, schedule_note=excluded.schedule_note,
                updated_at=excluded.updated_at, schedule_spec_json=excluded.schedule_spec_json;
            """)
        defer { statement.reset() }
        try statement.bind(1, definition.id.value.uuidString.lowercased())
        try statement.bind(2, definition.botID.value.uuidString.lowercased())
        try statement.bind(3, definition.name)
        try statement.bind(4, definition.prompt)
        try statement.bind(5, definition.scheduleNote)
        try statement.bind(6, string(definition.createdAt))
        try statement.bind(7, string(definition.updatedAt))
        try statement.bind(8, definition.scheduleSpecJSON)
        _ = try statement.step()
    }

    private func upsertActivation(_ activation: BotRoutineActivation, database: SQLiteDB) throws {
        let statement = try database.prepare("""
            INSERT INTO bot_routine_activations(
                routine_id, bot_id, is_enabled, last_test_run_requested_at, updated_at
            ) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(routine_id) DO UPDATE SET
                is_enabled=excluded.is_enabled,
                last_test_run_requested_at=excluded.last_test_run_requested_at,
                updated_at=excluded.updated_at;
            """)
        defer { statement.reset() }
        try statement.bind(1, activation.routineID.value.uuidString.lowercased())
        try statement.bind(2, activation.botID.value.uuidString.lowercased())
        try statement.bind(3, activation.isEnabled)
        try statement.bind(4, string(activation.lastTestRunRequestedAt))
        try statement.bind(5, string(activation.updatedAt))
        _ = try statement.step()
    }

    private func insertMemoryRevision(_ revision: BotMemoryItemRevision, database: SQLiteDB) throws {
        let statement = try database.prepare("""
            INSERT INTO bot_memory_item_revisions(
                id, item_id, bot_id, revision_number, content, provenance, trusted, source,
                created_at, supersedes_revision_id
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        defer { statement.reset() }
        try statement.bind(1, revision.id.uuidString.lowercased())
        try statement.bind(2, revision.itemID.value.uuidString.lowercased())
        try statement.bind(3, revision.botID.value.uuidString.lowercased())
        try statement.bind(4, revision.revisionNumber)
        try statement.bind(5, revision.content)
        try statement.bind(6, revision.provenance)
        try statement.bind(7, revision.trusted)
        try statement.bind(8, revision.source)
        try statement.bind(9, string(revision.createdAt))
        try statement.bind(10, revision.supersedesRevisionID?.uuidString.lowercased())
        _ = try statement.step()
    }

    private func executeBound(_ sql: String, id: BotID) throws {
        let statement = try db.prepare(sql)
        defer { statement.reset() }
        try statement.bind(1, id.value.uuidString.lowercased())
        _ = try statement.step()
    }

    private func loadQueuedFollowUps(botID: BotID, database: SQLiteDB) throws -> [BotQueuedFollowUpRecord] {
        let statement = try database.prepare(
            """
            SELECT id, bot_id, conversation_id, text, payload_json, sort_order, created_at
            FROM bot_queued_follow_ups
            WHERE bot_id = ?
            ORDER BY sort_order ASC;
            """
        )
        defer { statement.reset() }
        try statement.bind(1, botID.value.uuidString.lowercased())
        var rows: [BotQueuedFollowUpRecord] = []
        while try statement.step() {
            rows.append(try decodeQueuedFollowUp(statement))
        }
        return rows
    }

    private func nextQueuedFollowUpSortOrder(botID: BotID, database: SQLiteDB) throws -> Int {
        let statement = try database.prepare(
            "SELECT COALESCE(MAX(sort_order), -1) FROM bot_queued_follow_ups WHERE bot_id = ?;"
        )
        defer { statement.reset() }
        try statement.bind(1, botID.value.uuidString.lowercased())
        guard try statement.step() else { return 0 }
        return Int(statement.columnInt64(0)) + 1
    }

    private func insertQueuedFollowUp(_ record: BotQueuedFollowUpRecord, database: SQLiteDB) throws {
        let statement = try database.prepare(
            """
            INSERT INTO bot_queued_follow_ups(
                id, bot_id, conversation_id, text, payload_json, sort_order, created_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?);
            """
        )
        defer { statement.reset() }
        try statement.bind(1, record.id)
        try statement.bind(2, record.botID.value.uuidString.lowercased())
        try statement.bind(3, record.conversationID)
        try statement.bind(4, record.text)
        try statement.bind(5, record.payloadJSON)
        try statement.bind(6, record.sortOrder)
        try statement.bind(7, string(record.createdAt))
        _ = try statement.step()
#if DEBUG
        listCacheState.withLock { queuedFollowUpRowWriteCountForTesting += 1 }
#endif
    }

    private func deleteQueuedFollowUpsLocked(botID: BotID, database: SQLiteDB) throws {
        let statement = try database.prepare("DELETE FROM bot_queued_follow_ups WHERE bot_id = ?;")
        defer { statement.reset() }
        try statement.bind(1, botID.value.uuidString.lowercased())
        _ = try statement.step()
    }

    private func removeQueuedFollowUpLocked(botID: BotID, id: String, database: SQLiteDB) throws {
        let statement = try database.prepare(
            "DELETE FROM bot_queued_follow_ups WHERE bot_id = ? AND id = ?;"
        )
        defer { statement.reset() }
        try statement.bind(1, botID.value.uuidString.lowercased())
        try statement.bind(2, id)
        _ = try statement.step()
    }

    private func decodeQueuedFollowUp(_ statement: SQLiteStatement) throws -> BotQueuedFollowUpRecord {
        guard let id = statement.columnText(0),
              let botRaw = statement.columnText(1),
              let botUUID = UUID(uuidString: botRaw),
              let text = statement.columnText(3) else {
            throw BotStoreError.invalidRow("queued follow-up is missing identity")
        }
        return BotQueuedFollowUpRecord(
            id: id,
            botID: BotID(botUUID),
            conversationID: statement.columnText(2),
            text: text,
            payloadJSON: statement.columnText(4) ?? "{}",
            sortOrder: Int(statement.columnInt64(5)),
            createdAt: date(statement.columnText(6)) ?? Date(timeIntervalSince1970: 0)
        )
    }

    func loadBot(id: BotID, database: SQLiteDB) throws -> BotDefinition? {
        let statement = try database.prepare(try botSelect(database) + " WHERE id = ? LIMIT 1;")
        defer { statement.reset() }
        try statement.bind(1, id.value.uuidString.lowercased())
        return try statement.step() ? try decodeBot(statement) : nil
    }

    func loadRevision(id: BotRevisionID, database: SQLiteDB) throws -> BotRevision? {
        let statement = try database.prepare(Self.revisionSelect + " WHERE id = ? LIMIT 1;")
        defer { statement.reset() }
        try statement.bind(1, id.value.uuidString.lowercased())
        return try statement.step() ? try decodeRevision(statement) : nil
    }

    private func loadMemory(id: BotMemoryItemID, database: SQLiteDB) throws -> BotMemoryItem? {
        let statement = try database.prepare(Self.memorySelect + " WHERE i.id = ? LIMIT 1;")
        defer { statement.reset() }
        try statement.bind(1, id.value.uuidString.lowercased())
        return try statement.step() ? try decodeMemory(statement) : nil
    }

    private func loadActivation(routineID: BotRoutineID, database: SQLiteDB) throws -> BotRoutineActivation? {
        let statement = try database.prepare("""
            SELECT routine_id, bot_id, is_enabled, last_test_run_requested_at, updated_at
            FROM bot_routine_activations WHERE routine_id = ? LIMIT 1;
            """)
        defer { statement.reset() }
        try statement.bind(1, routineID.value.uuidString.lowercased())
        return try statement.step() ? try decodeActivation(statement) : nil
    }

    private func upsertSkillBinding(_ binding: BotSkillBinding, database: SQLiteDB) throws {
        let statement = try database.prepare("""
            INSERT INTO bot_skill_bindings(bot_id, skill_id, enabled, digest, updated_at)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(bot_id, skill_id) DO UPDATE SET
                enabled=excluded.enabled,
                digest=excluded.digest,
                updated_at=excluded.updated_at;
            """)
        defer { statement.reset() }
        try statement.bind(1, binding.botID.value.uuidString.lowercased())
        try statement.bind(2, binding.skillID)
        try statement.bind(3, binding.enabled)
        try statement.bind(4, binding.digest)
        try statement.bind(5, string(binding.updatedAt))
        _ = try statement.step()
    }

    private func loadSkillBindings(botID: BotID, database: SQLiteDB) throws -> [BotSkillBinding] {
        let statement = try database.prepare("""
            SELECT bot_id, skill_id, enabled, digest, updated_at
            FROM bot_skill_bindings
            WHERE bot_id = ?
            ORDER BY skill_id ASC;
            """)
        defer { statement.reset() }
        try statement.bind(1, botID.value.uuidString.lowercased())
        var result: [BotSkillBinding] = []
        while try statement.step() {
            result.append(try decodeSkillBinding(statement))
        }
        return result
    }

    private func decodeSkillBinding(_ statement: SQLiteStatement) throws -> BotSkillBinding {
        guard let bot = UUID(uuidString: statement.columnText(0) ?? ""),
              let skillID = statement.columnText(1),
              !skillID.isEmpty,
              let updated = date(statement.columnText(4)) else {
            throw BotStoreError.invalidRow("skill binding")
        }
        return BotSkillBinding(
            botID: BotID(bot),
            skillID: skillID,
            enabled: statement.columnInt64(2) != 0,
            digest: statement.columnText(3),
            updatedAt: updated
        )
    }

    private func loadRoutines(botID: BotID, database: SQLiteDB) throws -> [BotRoutine] {
        let statement = try database.prepare("""
            SELECT d.id, d.bot_id, d.name, d.prompt, d.schedule_note, d.created_at, d.updated_at, d.schedule_spec_json,
                   a.routine_id, a.bot_id, a.is_enabled, a.last_test_run_requested_at, a.updated_at
            FROM bot_routine_definitions d
            JOIN bot_routine_activations a ON a.routine_id = d.id
            WHERE d.bot_id = ?
            ORDER BY d.updated_at DESC;
            """)
        defer { statement.reset() }
        try statement.bind(1, botID.value.uuidString.lowercased())
        var result: [BotRoutine] = []
        while try statement.step() {
            let definition = try decodeRoutineDefinition(statement)
            let activation = try decodeActivation(statement, offset: 8)
            result.append(BotRoutine(definition: definition, activation: activation))
        }
        return result
    }

    private func nextRevisionNumber(botID: BotID, database: SQLiteDB) throws -> Int {
        let statement = try database.prepare(
            "SELECT COALESCE(MAX(revision_number), 0) FROM bot_revisions WHERE bot_id = ?;"
        )
        defer { statement.reset() }
        try statement.bind(1, botID.value.uuidString.lowercased())
        _ = try statement.step()
        return Int(statement.columnInt64(0)) + 1
    }

    private func nextMemoryRevisionNumber(itemID: BotMemoryItemID, database: SQLiteDB) throws -> Int {
        let statement = try database.prepare(
            "SELECT COALESCE(MAX(revision_number), 0) FROM bot_memory_item_revisions WHERE item_id = ?;"
        )
        defer { statement.reset() }
        try statement.bind(1, itemID.value.uuidString.lowercased())
        _ = try statement.step()
        return Int(statement.columnInt64(0)) + 1
    }

    private func decodeBot(_ statement: SQLiteStatement) throws -> BotDefinition {
        guard
            let idRaw = statement.columnText(0), let id = UUID(uuidString: idRaw),
            let handle = statement.columnText(1),
            let name = statement.columnText(2),
            let title = statement.columnText(3),
            let description = statement.columnText(4),
            let avatar = statement.columnText(5),
            let created = date(statement.columnText(11)),
            let updated = date(statement.columnText(12))
        else { throw BotStoreError.invalidRow("bots") }
        let revision = statement.columnText(8).flatMap(UUID.init(uuidString:)).map(BotRevisionID.init)
        let workspace = statement.columnText(14).flatMap(UUID.init(uuidString:)).map(WorkspaceID.init)
        return BotDefinition(
            id: BotID(id),
            handle: handle,
            name: name,
            title: title,
            description: description,
            avatarSymbol: avatar,
            pinned: statement.columnInt64(6) != 0,
            hidden: statement.columnInt64(7) != 0,
            currentRevisionID: revision,
            directoryEpoch: Int(statement.columnInt64(9)),
            notificationsEnabled: statement.columnInt64(10) != 0,
            verbosity: statement.columnText(15).flatMap(BotReplyVerbosity.init(rawValue:)) ?? .human,
            cavemanEnabled: statement.columnInt64(16) != 0,
            createdAt: created,
            updatedAt: updated,
            deletedAt: date(statement.columnText(13)),
            workspaceID: workspace,
            sortOrder: statement.columnIsNull(17) ? nil : Int(statement.columnInt64(17))
        )
    }

    private func decodeRevision(_ statement: SQLiteStatement) throws -> BotRevision {
        guard
            let idRaw = statement.columnText(0), let id = UUID(uuidString: idRaw),
            let botRaw = statement.columnText(1), let bot = UUID(uuidString: botRaw),
            let name = statement.columnText(3),
            let title = statement.columnText(4),
            let description = statement.columnText(5),
            let soul = statement.columnText(6),
            let permissionRaw = statement.columnText(12),
            let permission = AgentPermissionMode(rawValue: permissionRaw),
            let desktopRaw = statement.columnText(13),
            let desktop = BotDesktopKind(rawValue: desktopRaw),
            let digest = statement.columnText(14),
            let published = date(statement.columnText(15))
        else { throw BotStoreError.invalidRow("bot_revisions") }
        let supersedes = statement.columnText(16).flatMap(UUID.init(uuidString:)).map(BotRevisionID.init)
        return BotRevision(
            id: BotRevisionID(id),
            botID: BotID(bot),
            revisionNumber: Int(statement.columnInt64(2)),
            name: name,
            title: title,
            description: description,
            soul: soul,
            permissionMode: permission,
            desktopKind: desktop,
            digest: digest,
            publishedAt: published,
            supersedesRevisionID: supersedes
        )
    }

    func decodeConversation(_ statement: SQLiteStatement) throws -> BotConversation {
        guard
            let idRaw = statement.columnText(0), let id = UUID(uuidString: idRaw),
            let botRaw = statement.columnText(1), let bot = UUID(uuidString: botRaw),
            let title = statement.columnText(2),
            let stateRaw = statement.columnText(6),
            let state = BotAttentionState(rawValue: stateRaw),
            let created = date(statement.columnText(8)),
            let updated = date(statement.columnText(9))
        else { throw BotStoreError.invalidRow("bot_conversations") }
        let thread = statement.columnText(7).flatMap(UUID.init(uuidString:)).map(AgentThreadID.init)
        let conversation = BotConversation(
            id: BotConversationID(id),
            botID: BotID(bot),
            title: title,
            pinned: statement.columnInt64(3) != 0,
            hidden: statement.columnInt64(4) != 0,
            unread: statement.columnInt64(5) != 0,
            attentionState: state,
            linkedAgentThreadID: thread,
            createdAt: created,
            updatedAt: updated,
            groupID: statement.columnText(10).flatMap(UUID.init(uuidString:)).map(BotGroupID.init)
        )
        rememberLinkedThread(conversation)
        return conversation
    }

    private func decodeMemory(_ statement: SQLiteStatement) throws -> BotMemoryItem {
        guard
            let idRaw = statement.columnText(0), let id = UUID(uuidString: idRaw),
            let botRaw = statement.columnText(1), let bot = UUID(uuidString: botRaw),
            let revisionRaw = statement.columnText(2), let revision = UUID(uuidString: revisionRaw),
            let content = statement.columnText(5),
            let provenance = statement.columnText(6),
            let source = statement.columnText(8),
            let created = date(statement.columnText(10)),
            let updated = date(statement.columnText(11))
        else { throw BotStoreError.invalidRow("bot_memory_items") }
        return BotMemoryItem(
            id: BotMemoryItemID(id),
            botID: BotID(bot),
            currentRevisionID: revision,
            content: content,
            provenance: provenance,
            trusted: statement.columnInt64(7) != 0,
            source: source,
            forgottenAt: date(statement.columnText(3)),
            expiresAt: date(statement.columnText(4)),
            createdAt: created,
            updatedAt: updated
        )
    }

    private func decodeMemoryRevision(_ statement: SQLiteStatement) throws -> BotMemoryItemRevision {
        guard
            let idRaw = statement.columnText(0), let id = UUID(uuidString: idRaw),
            let itemRaw = statement.columnText(1), let item = UUID(uuidString: itemRaw),
            let botRaw = statement.columnText(2), let bot = UUID(uuidString: botRaw),
            let content = statement.columnText(4),
            let provenance = statement.columnText(5),
            let source = statement.columnText(7),
            let created = date(statement.columnText(8))
        else { throw BotStoreError.invalidRow("bot_memory_item_revisions") }
        return BotMemoryItemRevision(
            id: id,
            itemID: BotMemoryItemID(item),
            botID: BotID(bot),
            revisionNumber: Int(statement.columnInt64(3)),
            content: content,
            provenance: provenance,
            trusted: statement.columnInt64(6) != 0,
            source: source,
            createdAt: created,
            supersedesRevisionID: statement.columnText(9).flatMap(UUID.init(uuidString:))
        )
    }

    private func decodeAttention(_ statement: SQLiteStatement) throws -> BotAttentionItem {
        guard
            let idRaw = statement.columnText(0), let id = UUID(uuidString: idRaw),
            let botRaw = statement.columnText(1), let bot = UUID(uuidString: botRaw),
            let kindRaw = statement.columnText(3), let kind = BotAttentionItemKind(rawValue: kindRaw),
            let title = statement.columnText(4),
            let detail = statement.columnText(5),
            let created = date(statement.columnText(6))
        else { throw BotStoreError.invalidRow("bot_attention_items") }
        let conversation = statement.columnText(2).flatMap(UUID.init(uuidString:)).map(BotConversationID.init)
        return BotAttentionItem(
            id: BotAttentionItemID(id),
            botID: BotID(bot),
            conversationID: conversation,
            kind: kind,
            title: title,
            detail: detail,
            createdAt: created,
            acknowledgedAt: date(statement.columnText(7))
        )
    }

    private func decodeRoutineDefinition(_ statement: SQLiteStatement) throws -> BotRoutineDefinition {
        guard
            let idRaw = statement.columnText(0), let id = UUID(uuidString: idRaw),
            let botRaw = statement.columnText(1), let bot = UUID(uuidString: botRaw),
            let name = statement.columnText(2),
            let prompt = statement.columnText(3),
            let note = statement.columnText(4),
            let created = date(statement.columnText(5)),
            let updated = date(statement.columnText(6))
        else { throw BotStoreError.invalidRow("bot_routine_definitions") }
        return BotRoutineDefinition(
            id: BotRoutineID(id),
            botID: BotID(bot),
            name: name,
            prompt: prompt,
            scheduleNote: note,
            scheduleSpecJSON: statement.columnText(7) ?? "",
            createdAt: created,
            updatedAt: updated
        )
    }

    private func decodeActivation(_ statement: SQLiteStatement, offset: Int32 = 0) throws -> BotRoutineActivation {
        guard
            let idRaw = statement.columnText(offset), let id = UUID(uuidString: idRaw),
            let botRaw = statement.columnText(offset + 1), let bot = UUID(uuidString: botRaw),
            let updated = date(statement.columnText(offset + 4))
        else { throw BotStoreError.invalidRow("bot_routine_activations") }
        return BotRoutineActivation(
            routineID: BotRoutineID(id),
            botID: BotID(bot),
            isEnabled: statement.columnInt64(offset + 2) != 0,
            lastTestRunRequestedAt: date(statement.columnText(offset + 3)),
            updatedAt: updated
        )
    }

    private func encodeRoutes(_ routes: [String]) throws -> String {
        guard let string = String(data: try encoder.encode(routes), encoding: .utf8) else {
            throw BotStoreError.invalidRow("compatible_route_set is not UTF-8")
        }
        return string
    }

    func string(_ date: Date?) -> String? {
        date.map { dates.string(from: $0) }
    }

    func date(_ string: String?) -> Date? {
        string.flatMap(dates.date(from:))
    }

    /// Restore review reads bots from trusted legacy schemas (v93/v96) that
    /// predate `sort_order`; those select NULL for it. Only a positive probe is
    /// cached, so a database migrated later is re-probed.
    private let sortOrderColumnState = OSAllocatedUnfairLock(initialState: false)

    private func botSelect(_ database: SQLiteDB) throws -> String {
        var hasSortOrder = sortOrderColumnState.withLock { $0 }
        if !hasSortOrder {
            let info = try database.prepare("PRAGMA table_info(bots);")
            defer { info.reset() }
            while try info.step() { if info.columnText(1) == "sort_order" { hasSortOrder = true; break } }
            if hasSortOrder { sortOrderColumnState.withLock { $0 = true } }
        }
        return """
            SELECT id, handle, name, title, description, avatar_symbol, pinned, hidden,
                   current_revision_id, directory_epoch, notifications_enabled,
                   created_at, updated_at, deleted_at, workspace_id,
                   reply_verbosity, caveman_enabled, \(hasSortOrder ? "sort_order" : "NULL AS sort_order")
            FROM bots
            """
    }

    private static let revisionSelect = """
        SELECT id, bot_id, revision_number, name, title, description, soul, provider,
               provider_instance_id, model, reasoning_effort, compatible_route_set_json,
               permission_mode, desktop_kind, digest, published_at, supersedes_revision_id
        FROM bot_revisions
        """

    static let conversationSelect = """
        SELECT id, bot_id, title, pinned, hidden,
               CASE
                   WHEN linked_agent_thread_id IS NOT NULL
                    AND (
                        NOT EXISTS (
                            SELECT 1 FROM agent_threads
                            WHERE agent_threads.id = bot_conversations.linked_agent_thread_id COLLATE NOCASE
                        )
                        OR (
                            NOT EXISTS (
                                SELECT 1 FROM agent_messages
                                WHERE agent_messages.thread_id = bot_conversations.linked_agent_thread_id COLLATE NOCASE
                            )
                            AND NOT EXISTS (
                                SELECT 1 FROM agent_runs
                                WHERE agent_runs.thread_id = bot_conversations.linked_agent_thread_id COLLATE NOCASE
                            )
                        )
                    )
                   THEN 0
                   ELSE unread
               END AS unread,
               CASE
                   WHEN linked_agent_thread_id IS NOT NULL
                    AND (
                        NOT EXISTS (
                            SELECT 1 FROM agent_threads
                            WHERE agent_threads.id = bot_conversations.linked_agent_thread_id COLLATE NOCASE
                        )
                        OR (
                            NOT EXISTS (
                                SELECT 1 FROM agent_messages
                                WHERE agent_messages.thread_id = bot_conversations.linked_agent_thread_id COLLATE NOCASE
                            )
                            AND NOT EXISTS (
                                SELECT 1 FROM agent_runs
                                WHERE agent_runs.thread_id = bot_conversations.linked_agent_thread_id COLLATE NOCASE
                            )
                        )
                    )
                   THEN 'none'
                   WHEN attention_state = 'needsAttention'
                    AND EXISTS (
                        SELECT 1 FROM bot_attention_items
                        WHERE conversation_id = bot_conversations.id
                    )
                    AND NOT EXISTS (
                        SELECT 1 FROM bot_attention_items
                        WHERE conversation_id = bot_conversations.id AND \(openAttentionPredicate)
                    )
                   THEN CASE
                       WHEN (SELECT status FROM agent_runs
                             WHERE thread_id = bot_conversations.linked_agent_thread_id COLLATE NOCASE
                             ORDER BY started_at DESC, rowid DESC LIMIT 1) IN ('pending', 'running') THEN 'working'
                       WHEN unread = 1 THEN 'unreadActivity'
                       ELSE 'none'
                   END
                   ELSE attention_state
               END AS attention_state,
               linked_agent_thread_id, created_at, updated_at, group_id
        FROM bot_conversations
        """

    private static let memorySelect = """
        SELECT i.id, i.bot_id, i.current_revision_id, i.forgotten_at, i.expires_at,
               r.content, r.provenance, r.trusted, r.source, r.id,
               i.created_at, i.updated_at
        FROM bot_memory_items i
        LEFT JOIN bot_memory_item_revisions r ON r.id = i.current_revision_id
        """

    private static let attentionSelect = """
        SELECT id, bot_id, conversation_id, kind, title, detail, created_at, acknowledged_at
        FROM bot_attention_items
        """

    /// Also settles receipts written by older versions. All inboxes and Bot
    /// badges use the same durable evidence; reading a conversation alone is
    /// never evidence that its question or failure was handled.
    private static let openAttentionPredicate = """
        acknowledged_at IS NULL
        AND NOT EXISTS (
            SELECT 1 FROM bot_conversations AS owner
            WHERE owner.id = bot_attention_items.conversation_id
              AND (
                  (bot_attention_items.kind IN ('question', 'blocked', 'handoff') AND EXISTS (
                      SELECT 1 FROM agent_messages
                      WHERE thread_id = owner.linked_agent_thread_id COLLATE NOCASE
                        AND role = 'user' AND julianday(created_at) > julianday(bot_attention_items.created_at)
                  ))
                  OR (bot_attention_items.kind IN ('blocked', 'handoff') AND EXISTS (
                      SELECT 1 FROM agent_runs
                      WHERE thread_id = owner.linked_agent_thread_id COLLATE NOCASE
                        AND julianday(started_at) > julianday(bot_attention_items.created_at)
                  ))
              )
        )
        """
}
