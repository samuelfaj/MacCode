import CoreModel
import Foundation

/// What a flush posts for a batch of pending rows (built by the caller's compose step).
public struct TitioNoticePosting: Equatable, Sendable {
    public var messageID: String
    /// Set for digests (2+ rows in one message).
    public var batchID: String?
    /// The row whose `actions_json` holds the card; other rows in the batch get no actions.
    public var cardOwnerKey: String?
    /// Labeled card options in display order; nil = no card.
    public var cardOptions: [TitioNoticeCardOption]?
    /// Inbox preview (first line of the message).
    public var preview: String
    /// False while the inbox is being viewed, so the post does not bump unread.
    public var countsAsUnread: Bool
    public var notificationLine: String?

    public init(
        messageID: String,
        batchID: String? = nil,
        cardOwnerKey: String? = nil,
        cardOptions: [TitioNoticeCardOption]? = nil,
        preview: String,
        countsAsUnread: Bool = true,
        notificationLine: String? = nil
    ) {
        self.messageID = messageID
        self.batchID = batchID
        self.cardOwnerKey = cardOwnerKey
        self.cardOptions = cardOptions
        self.preview = preview
        self.countsAsUnread = countsAsUnread
        self.notificationLine = notificationLine
    }
}

public struct TitioNoticeFlushResult: Equatable, Sendable {
    /// The rows this flush posted, as stored after the commit.
    public var records: [TitioNoticeRecord]
    public var posting: TitioNoticePosting
    public var inbox: TitioInboxState
}

/// Outcome of a source-side resolution (`sourceResolved`).
public enum TitioNoticeSourceOutcome: Equatable, Sendable {
    /// The row was still pending: dropped, never posted, nothing to rewrite.
    case dropped
    /// The row was posted (or armed): now resolved; the caller rewrites `messageID`.
    case resolved(TitioNoticeRecord)
    /// Missing, already terminal, or `acting` (the host's own act owns it).
    case unchanged
}

/// Durable Titio notice ledger (`titio_notices`, `titio_inbox_state`, schema v93).
/// Every method is synchronous SQLite: call it off the MainActor.
public final class TitioNoticeRepository: @unchecked Sendable {
    private let db: SQLiteDB
    private static let columns = """
        key, kind, urgency, source_json, facts_json, actions_json, state, resolution,
        message_id, batch_id, occurred_at, posted_at, banner_at, resolved_at
        """

    public init(db: SQLiteDB) { self.db = db }

    // MARK: Ingest

    /// Upserts one notice by key. A new key becomes a `pending` row. An existing
    /// key merges facts and source (JSON merge patch) and takes a provided card
    /// only while the row is still `pending`; once posted, the row is frozen, so a
    /// replay or a second producer can never create or change a second notice.
    /// Returns the row as stored.
    @discardableResult
    public func ingest(_ fact: TitioNoticeFact) throws -> TitioNoticeRecord? {
        let source = try Self.json(fact.source)
        let facts = try Self.json(fact.facts)
        let actions = try fact.actions.map { try Self.json($0.map { TitioNoticeCardOption(label: nil, action: $0) }) }
        return try db.performSync { database in
            try database.transaction {
                let statement = try database.prepare("""
                    INSERT INTO titio_notices(key, kind, urgency, source_json, facts_json, actions_json, state, occurred_at)
                    VALUES (?, ?, ?, ?, ?, ?, 'pending', ?)
                    ON CONFLICT(key) DO UPDATE SET
                        facts_json = json_patch(titio_notices.facts_json, excluded.facts_json),
                        source_json = json_patch(titio_notices.source_json, excluded.source_json),
                        actions_json = COALESCE(excluded.actions_json, titio_notices.actions_json)
                    WHERE titio_notices.state = 'pending';
                    """)
                try statement.bind(1, fact.key)
                try statement.bind(2, fact.kind.rawValue)
                try statement.bind(3, fact.urgency.rawValue)
                try statement.bind(4, source)
                try statement.bind(5, facts)
                try statement.bind(6, actions)
                try statement.bind(7, fact.occurredAt.timeIntervalSince1970)
                _ = try statement.step()
                return try Self.fetch(database, key: fact.key)
            }
        }
    }

    // MARK: Reads

    public func get(key: String) throws -> TitioNoticeRecord? {
        try db.performSync { try Self.fetch($0, key: key) }
    }

    /// Pending rows, oldest first.
    public func listPending(limit: Int = 500) throws -> [TitioNoticeRecord] {
        try query("SELECT \(Self.columns) FROM titio_notices WHERE state = 'pending' ORDER BY occurred_at, key LIMIT ?;") {
            try $0.bind(1, limit)
        }
    }

    /// The rows of `keys` that are still `pending`, oldest first (what a
    /// flush would post). The voice writes their text before the flush.
    public func pendingRows(keys: [String]) throws -> [TitioNoticeRecord] {
        let unique = Array(Set(keys)).sorted()
        guard !unique.isEmpty else { return [] }
        return try db.performSync { database in
            try Self.fetchAll(database, keys: unique).filter { $0.state == .pending }
                .sorted { $0.occurredAt == $1.occurredAt ? $0.key < $1.key : $0.occurredAt < $1.occurredAt }
        }
    }

    /// The row that owns the card in `messageID` (a digest shares one message
    /// across rows; the card owner has `actions_json`), else its oldest row.
    public func notice(messageID: String) throws -> TitioNoticeRecord? {
        try notices(messageID: messageID).first
    }

    /// Every row posted in `messageID`, card owner first, then oldest first.
    public func notices(messageID: String) throws -> [TitioNoticeRecord] {
        try query("""
            SELECT \(Self.columns) FROM titio_notices WHERE message_id = ?
            ORDER BY (actions_json IS NULL), occurred_at, key;
            """) { try $0.bind(1, messageID) }
    }

    /// Rows posted after `since` (any state), oldest first, newest `limit` only.
    /// Feeds `TitioNoticeDirective`.
    public func recentPosted(since: Date, limit: Int = TitioNoticeDirective.maxRows) throws -> [TitioNoticeRecord] {
        let newestFirst = try query("""
            SELECT \(Self.columns) FROM titio_notices
            WHERE posted_at IS NOT NULL AND posted_at > ?
            ORDER BY posted_at DESC, key DESC LIMIT ?;
            """) {
            try $0.bind(1, since.timeIntervalSince1970)
            try $0.bind(2, limit)
        }
        return newestFirst.reversed()
    }

    /// Rows posted inside `window` whose banner never went out (crash between
    /// commit and banner). Startup re-posts them with the same identifier.
    public func rowsNeedingBannerRepost(now: Date, window: TimeInterval = TitioNoticeTiming.bannerRepostWindow) throws -> [TitioNoticeRecord] {
        try query("""
            SELECT \(Self.columns) FROM titio_notices
            WHERE posted_at IS NOT NULL AND posted_at >= ? AND banner_at IS NULL AND message_id IS NOT NULL
            ORDER BY posted_at, key;
            """) { try $0.bind(1, now.addingTimeInterval(-window).timeIntervalSince1970) }
    }

    /// Open decisions: posted rows the user still has to decide on (state
    /// `posted`, `acting` or `awaiting_reply`, urgency `decision`). Drives the
    /// inbox conversation's `needsAttention` state and `titio_inbox.open_decisions`.
    public func openDecisionCount() throws -> Int {
        try db.performSync { database in
            let statement = try database.prepare("""
                SELECT COUNT(*) FROM titio_notices
                WHERE urgency = 'decision' AND state IN ('posted', 'acting', 'awaiting_reply');
                """)
            defer { statement.reset() }
            guard try statement.step() else { return 0 }
            return Int(statement.columnInt64(0))
        }
    }

    /// Keys starting with `prefix` whose notice is still open (`pending`,
    /// `posted`, `acting`, `awaiting_reply`). The bot-attention projector uses
    /// it to resolve items acknowledged elsewhere and to skip Bot items that a
    /// thread request notice already covers.
    public func openKeys(prefix: String) throws -> Set<String> {
        try db.performSync { database in
            let statement = try database.prepare("""
                SELECT key FROM titio_notices
                WHERE substr(key, 1, ?) = ? AND state IN ('pending', 'posted', 'acting', 'awaiting_reply');
                """)
            defer { statement.reset() }
            try statement.bind(1, prefix.count)
            try statement.bind(2, prefix)
            var keys = Set<String>()
            while try statement.step() {
                if let key = statement.columnText(0) { keys.insert(key) }
            }
            return keys
        }
    }

    /// Rows in `states`, oldest first. Startup reconciliation reads `acting`
    /// rows (an act no live task owns) and open request rows with it.
    public func rows(inStates states: Set<TitioNoticeState>, limit: Int = 500) throws -> [TitioNoticeRecord] {
        guard !states.isEmpty else { return [] }
        let values = states.map(\.rawValue).sorted()
        let placeholders = Array(repeating: "?", count: values.count).joined(separator: ",")
        return try query("""
            SELECT \(Self.columns) FROM titio_notices WHERE state IN (\(placeholders))
            ORDER BY occurred_at, key LIMIT ?;
            """) { statement in
            for (index, value) in values.enumerated() { try statement.bind(Int32(index + 1), value) }
            try statement.bind(Int32(values.count + 1), limit)
        }
    }

    /// Labels of recently posted cards. A card tap is stored as a user row
    /// with its label, so the §16 language rule skips texts equal to one.
    public func recentCardLabels(limit: Int = 50) throws -> Set<String> {
        let rows = try query("""
            SELECT \(Self.columns) FROM titio_notices
            WHERE actions_json IS NOT NULL AND posted_at IS NOT NULL
            ORDER BY posted_at DESC LIMIT ?;
            """) { try $0.bind(1, limit) }
        return Set(rows.flatMap { $0.actions ?? [] }.compactMap { $0.label?.trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    /// Posted rows whose card the user can still tap (`posted` or
    /// `awaiting_reply` with `actions_json`), oldest first. The hub mirrors
    /// them in memory for the old-iOS exact-option-text intercept (§7).
    public func openCards(limit: Int = 200) throws -> [TitioNoticeRecord] {
        try query("""
            SELECT \(Self.columns) FROM titio_notices
            WHERE state IN ('posted', 'awaiting_reply') AND actions_json IS NOT NULL AND message_id IS NOT NULL
              AND urgency != 'info'
            ORDER BY posted_at, key LIMIT ?;
            """) { try $0.bind(1, limit) }
    }

    // MARK: Flush

    /// One transaction: re-reads which of `keys` are still `pending` (resolved or
    /// dropped rows are skipped, which is how flapping notices disappear), hands
    /// them to `compose` (which may write the Titio message on this same
    /// connection, e.g. `AgentMessageRepository.append`, but must not open a
    /// transaction), then marks them `posted` and updates the inbox state.
    /// Returns nil when nothing was pending or `compose` returned nil; then
    /// nothing changes. A throw from `compose` rolls everything back.
    public func flush(
        keys: [String],
        postedAt: Date,
        compose: ([TitioNoticeRecord]) throws -> TitioNoticePosting?
    ) throws -> TitioNoticeFlushResult? {
        let unique = Array(Set(keys)).sorted()
        guard !unique.isEmpty else { return nil }
        return try db.performSync { database in
            try database.transaction {
                let pending = try Self.fetchAll(database, keys: unique).filter { $0.state == .pending }
                    .sorted { $0.occurredAt == $1.occurredAt ? $0.key < $1.key : $0.occurredAt < $1.occurredAt }
                guard !pending.isEmpty, let posting = try compose(pending) else { return nil }
                let owner = posting.cardOptions == nil ? nil : (posting.cardOwnerKey ?? pending[0].key)
                let ownerActions = try posting.cardOptions.map { try Self.json($0) }
                let update = try database.prepare("""
                    UPDATE titio_notices
                    SET state = 'posted', message_id = ?, batch_id = ?, posted_at = ?, actions_json = ?, facts_json = ?
                    WHERE key = ? AND state = 'pending';
                    """)
                for row in pending {
                    try update.bind(1, posting.messageID)
                    try update.bind(2, posting.batchID)
                    try update.bind(3, postedAt.timeIntervalSince1970)
                    try update.bind(4, row.key == owner ? ownerActions : nil)
                    var facts = row.facts
                    facts.generatedNotificationLine = posting.notificationLine
                    try update.bind(5, Self.json(facts))
                    try update.bind(6, row.key)
                    _ = try update.step()
                    update.reset()
                }
                var inbox = try Self.fetchInbox(database)
                if posting.countsAsUnread { inbox.unreadCount += 1 }
                // Latest-wins: an older post never overwrites a newer preview.
                if inbox.lastAt.map({ postedAt >= $0 }) ?? true {
                    inbox.lastPreview = posting.preview
                    inbox.lastAt = postedAt
                }
                try Self.storeInbox(database, inbox)
                let records = try Self.fetchAll(database, keys: pending.map(\.key))
                return TitioNoticeFlushResult(records: records, posting: posting, inbox: inbox)
            }
        }
    }

    /// Records that the banner/push for these rows went out.
    public func markBanner(keys: [String], at date: Date) throws {
        guard !keys.isEmpty else { return }
        try db.performSync { database in
            try database.transaction {
                let statement = try database.prepare("UPDATE titio_notices SET banner_at = ? WHERE key = ?;")
                for key in Set(keys) {
                    try statement.bind(1, date.timeIntervalSince1970)
                    try statement.bind(2, key)
                    _ = try statement.step()
                    statement.reset()
                }
            }
        }
    }

    // MARK: Act

    /// Atomic claim for an act: `posted|awaiting_reply → acting`. Exactly one
    /// concurrent caller wins; the others get false (`already_resolved`).
    public func claim(key: String) throws -> Bool {
        try transition(key: key, from: [.posted, .awaitingReply], to: .acting)
    }

    /// `acting|awaiting_reply → posted`: an act that could not start, or an arm
    /// that was cleared, gives the card back. Clears the inbox arm if it was this row.
    @discardableResult
    public func reopen(key: String) throws -> Bool {
        try db.performSync { database in
            try database.transaction {
                guard try Self.transitionLocked(database, key: key, from: [.acting, .awaitingReply], to: .posted) else { return false }
                var inbox = try Self.fetchInbox(database)
                if inbox.armedReplyKey == key {
                    inbox.armedReplyKey = nil
                    inbox.armedAt = nil
                    try Self.storeInbox(database, inbox)
                }
                return true
            }
        }
    }

    /// `awaiting_reply → posted` only: an arm that expired or was replaced by
    /// another tap gives the card back. Never touches a row an act claimed.
    @discardableResult
    public func disarm(key: String) throws -> Bool {
        try db.performSync { database in
            try database.transaction {
                guard try Self.transitionLocked(database, key: key, from: [.awaitingReply], to: .posted) else { return false }
                var inbox = try Self.fetchInbox(database)
                if inbox.armedReplyKey == key {
                    inbox.armedReplyKey = nil
                    inbox.armedAt = nil
                    try Self.storeInbox(database, inbox)
                }
                return true
            }
        }
    }

    /// "Reply here": `acting → awaiting_reply` and arms the inbox for this key.
    /// A previously armed row goes back to `posted`, so only one arm is live.
    @discardableResult
    public func setAwaitingReply(key: String, at date: Date) throws -> Bool {
        try db.performSync { database in
            try database.transaction {
                guard try Self.transitionLocked(database, key: key, from: [.acting], to: .awaitingReply) else { return false }
                var inbox = try Self.fetchInbox(database)
                if let previous = inbox.armedReplyKey, previous != key {
                    _ = try Self.transitionLocked(database, key: previous, from: [.awaitingReply], to: .posted)
                }
                inbox.armedReplyKey = key
                inbox.armedAt = date
                try Self.storeInbox(database, inbox)
                return true
            }
        }
    }

    /// Finishes an act: `acting → resolved` with `resolution`. Only the claimer
    /// calls this, after the host result. Clears the inbox arm if it was this row.
    @discardableResult
    public func resolve(key: String, resolution: TitioNoticeResolution, at date: Date) throws -> TitioNoticeRecord? {
        try db.performSync { database in
            try database.transaction {
                guard try Self.finishLocked(database, key: key, from: [.acting], state: .resolved, resolution: resolution, at: date) else {
                    return nil
                }
                return try Self.fetch(database, key: key)
            }
        }
    }

    /// The source resolved on its own (request answered elsewhere, ssh
    /// reconnected, attention acknowledged…): a `pending` row is dropped, a
    /// `posted`/`awaiting_reply` row is resolved. An `acting` row is left to the
    /// act that claimed it, so the host's own response never double-resolves.
    public func resolveFromSource(key: String, resolution: TitioNoticeResolution, at date: Date) throws -> TitioNoticeSourceOutcome {
        try db.performSync { database in
            try database.transaction {
                guard let row = try Self.fetch(database, key: key) else { return .unchanged }
                switch row.state {
                case .pending:
                    _ = try Self.finishLocked(database, key: key, from: [.pending], state: .dropped, resolution: resolution, at: date)
                    return .dropped
                case .posted, .awaitingReply:
                    _ = try Self.finishLocked(database, key: key, from: [.posted, .awaitingReply], state: .resolved, resolution: resolution, at: date)
                    return try Self.fetch(database, key: key).map(TitioNoticeSourceOutcome.resolved) ?? .unchanged
                case .acting, .resolved, .dropped:
                    return .unchanged
                }
            }
        }
    }

    /// `pending → dropped` (default resolution `flap`). False when the row was
    /// already posted or terminal.
    @discardableResult
    public func drop(key: String, resolution: TitioNoticeResolution = .flap, at date: Date) throws -> Bool {
        try db.performSync { database in
            try database.transaction {
                try Self.finishLocked(database, key: key, from: [.pending], state: .dropped, resolution: resolution, at: date)
            }
        }
    }

    // MARK: Inbox state

    public func inboxState() throws -> TitioInboxState {
        try db.performSync { try Self.fetchInbox($0) }
    }

    /// Atomic read-modify-write of the singleton inbox row.
    @discardableResult
    public func updateInboxState(_ mutate: (inout TitioInboxState) -> Void) throws -> TitioInboxState {
        try db.performSync { database in
            try database.transaction {
                var inbox = try Self.fetchInbox(database)
                mutate(&inbox)
                try Self.storeInbox(database, inbox)
                return inbox
            }
        }
    }

    // MARK: Retention

    /// Deletes `resolved`/`dropped` rows that ended before `cutoff`, and
    /// posted rows nothing can ever resolve: no card, not a decision, banner
    /// delivered, posted before `cutoff` (run completions, Bot replies,
    /// card-less alerts, the non-owner rows of a digest). Without the second
    /// rule those rows stay `posted` forever and the ledger grows with every
    /// run. Open decisions and rows with a card are never pruned. Messages
    /// are untouched.
    @discardableResult
    public func prune(endedBefore cutoff: Date) throws -> Int {
        try db.performSync { database in
            try database.transaction {
                let statement = try database.prepare("""
                    DELETE FROM titio_notices
                    WHERE (state IN ('resolved', 'dropped') AND COALESCE(resolved_at, occurred_at) < ?)
                       OR (state = 'posted' AND urgency != 'decision' AND actions_json IS NULL
                           AND banner_at IS NOT NULL AND posted_at < ?);
                    """)
                try statement.bind(1, cutoff.timeIntervalSince1970)
                try statement.bind(2, cutoff.timeIntervalSince1970)
                _ = try statement.step()
                return try Self.changes(database)
            }
        }
    }

    // MARK: Private

    private func query(_ sql: String, bind: (SQLiteStatement) throws -> Void) throws -> [TitioNoticeRecord] {
        try db.performSync { database in
            let statement = try database.prepare(sql)
            try bind(statement)
            var rows: [TitioNoticeRecord] = []
            while try statement.step() {
                if let row = Self.decode(statement) { rows.append(row) }
            }
            return rows
        }
    }

    private func transition(key: String, from: Set<TitioNoticeState>, to: TitioNoticeState) throws -> Bool {
        try db.performSync { database in
            try database.transaction { try Self.transitionLocked(database, key: key, from: from, to: to) }
        }
    }

    private static func transitionLocked(_ db: SQLiteDB, key: String, from: Set<TitioNoticeState>, to: TitioNoticeState) throws -> Bool {
        let states = from.map(\.rawValue).sorted()
        let placeholders = Array(repeating: "?", count: states.count).joined(separator: ",")
        let statement = try db.prepare("UPDATE titio_notices SET state = ? WHERE key = ? AND state IN (\(placeholders));")
        try statement.bind(1, to.rawValue)
        try statement.bind(2, key)
        for (index, state) in states.enumerated() { try statement.bind(Int32(index + 3), state) }
        _ = try statement.step()
        statement.reset()
        return try changes(db) > 0
    }

    private static func finishLocked(
        _ db: SQLiteDB,
        key: String,
        from: Set<TitioNoticeState>,
        state: TitioNoticeState,
        resolution: TitioNoticeResolution,
        at date: Date
    ) throws -> Bool {
        let states = from.map(\.rawValue).sorted()
        let placeholders = Array(repeating: "?", count: states.count).joined(separator: ",")
        let statement = try db.prepare("""
            UPDATE titio_notices SET state = ?, resolution = ?, resolved_at = ?
            WHERE key = ? AND state IN (\(placeholders));
            """)
        try statement.bind(1, state.rawValue)
        try statement.bind(2, resolution.rawValue)
        try statement.bind(3, date.timeIntervalSince1970)
        try statement.bind(4, key)
        for (index, value) in states.enumerated() { try statement.bind(Int32(index + 5), value) }
        _ = try statement.step()
        statement.reset()
        guard try changes(db) > 0 else { return false }
        var inbox = try fetchInbox(db)
        if inbox.armedReplyKey == key {
            inbox.armedReplyKey = nil
            inbox.armedAt = nil
            try storeInbox(db, inbox)
        }
        return true
    }

    private static func changes(_ db: SQLiteDB) throws -> Int {
        let statement = try db.prepare("SELECT changes();")
        defer { statement.reset() }
        guard try statement.step() else { return 0 }
        return Int(statement.columnInt64(0))
    }

    private static func fetch(_ db: SQLiteDB, key: String) throws -> TitioNoticeRecord? {
        let statement = try db.prepare("SELECT \(columns) FROM titio_notices WHERE key = ? LIMIT 1;")
        defer { statement.reset() }
        try statement.bind(1, key)
        guard try statement.step() else { return nil }
        return decode(statement)
    }

    private static func fetchAll(_ db: SQLiteDB, keys: [String]) throws -> [TitioNoticeRecord] {
        try keys.compactMap { try fetch(db, key: $0) }
    }

    private static func fetchInbox(_ db: SQLiteDB) throws -> TitioInboxState {
        let statement = try db.prepare("""
            SELECT conversation_id, unread_count, last_preview, last_at, armed_reply_key, armed_at
            FROM titio_inbox_state WHERE id = 1;
            """)
        defer { statement.reset() }
        guard try statement.step() else { return TitioInboxState() }
        return TitioInboxState(
            conversationID: statement.columnText(0),
            unreadCount: Int(statement.columnInt64(1)),
            lastPreview: statement.columnText(2),
            lastAt: date(statement, 3),
            armedReplyKey: statement.columnText(4),
            armedAt: date(statement, 5)
        )
    }

    private static func storeInbox(_ db: SQLiteDB, _ inbox: TitioInboxState) throws {
        let statement = try db.prepare("""
            INSERT INTO titio_inbox_state(id, conversation_id, unread_count, last_preview, last_at, armed_reply_key, armed_at)
            VALUES (1, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                conversation_id = excluded.conversation_id,
                unread_count = excluded.unread_count,
                last_preview = excluded.last_preview,
                last_at = excluded.last_at,
                armed_reply_key = excluded.armed_reply_key,
                armed_at = excluded.armed_at;
            """)
        defer { statement.reset() }
        try statement.bind(1, inbox.conversationID)
        try statement.bind(2, max(0, inbox.unreadCount))
        try statement.bind(3, inbox.lastPreview)
        try statement.bind(4, inbox.lastAt?.timeIntervalSince1970)
        try statement.bind(5, inbox.armedReplyKey)
        try statement.bind(6, inbox.armedAt?.timeIntervalSince1970)
        _ = try statement.step()
    }

    private static func decode(_ statement: SQLiteStatement) -> TitioNoticeRecord? {
        guard let key = statement.columnText(0),
              let kind = statement.columnText(1).flatMap(TitioNoticeKind.init(rawValue:)),
              let urgency = statement.columnText(2).flatMap(TitioNoticeUrgency.init(rawValue:)),
              let state = statement.columnText(6).flatMap(TitioNoticeState.init(rawValue:)) else { return nil }
        let decoder = JSONDecoder()
        let source = statement.columnText(3).flatMap { try? decoder.decode(TitioNoticeSource.self, from: Data($0.utf8)) }
        let facts = statement.columnText(4).flatMap { try? decoder.decode(TitioNoticeFacts.self, from: Data($0.utf8)) }
        let actions = statement.columnText(5).flatMap { try? decoder.decode([TitioNoticeCardOption].self, from: Data($0.utf8)) }
        return TitioNoticeRecord(
            key: key,
            kind: kind,
            urgency: urgency,
            source: source ?? TitioNoticeSource(),
            facts: facts ?? TitioNoticeFacts(),
            actions: actions,
            state: state,
            resolution: statement.columnText(7).flatMap(TitioNoticeResolution.init(rawValue:)),
            messageID: statement.columnText(8),
            batchID: statement.columnText(9),
            occurredAt: Date(timeIntervalSince1970: statement.columnDouble(10)),
            postedAt: date(statement, 11),
            bannerAt: date(statement, 12),
            resolvedAt: date(statement, 13)
        )
    }

    private static func date(_ statement: SQLiteStatement, _ index: Int32) -> Date? {
        statement.columnIsNull(index) ? nil : Date(timeIntervalSince1970: statement.columnDouble(index))
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
