import AgentRuntime
import CoreModel
import CryptoKit
import Darwin
import Foundation
import Persistence

/// Coordinates the SQLite restore with the native histories owned by the host.
enum HostScopedSessionBackup {
    struct Review {
        let database: HostDatabaseRestore.Review
        let fingerprint: String
        let scopedSessionCount: Int
        let requiresConfirmation: Bool
    }

    private struct Journal: Codable {
        let version: Int
        let stageName: String
        let currentPath: String
        let recoveryName: String
        let stagedFingerprint: String
        let recoveryFingerprint: String
        let incomingDigest: String
        let recoveryDigest: String
        let hadBindingsRoot: Bool
        var filesReady: Bool
    }

    private static let journalName = ".scoped-session-restore.json"
    private static let excludedHomeNames: Set<String> = [
        "config.toml", "auth.json", "claude-auth.json", "codex-auth.json",
        "openrouter-auth.json", "accounts", ".env", ".mcp.json", ".DS_Store"
    ]

    private static func failure(_ message: String) -> Error {
        SQLiteError.execute(message)
    }

    private static func exists(_ name: String, in directory: PrivateDirectory) throws -> Bool {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw failure(L("invalid scoped restore component"))
        }
        return try PrivateDirectoryTree.childNames(directory).contains(name)
    }

    private static func child(_ name: String, in directory: PrivateDirectory, create: Bool) throws -> PrivateDirectory {
        let result = try directory.child(name, create: create)
        if create { try directory.synchronize() }
        return result
    }

    private static func copyDirectory(from source: URL, to destination: URL) throws {
        let sourceDirectory = try PrivateDirectory(source, create: false)
        defer { sourceDirectory.close() }
        let destinationDirectory = try PrivateDirectory(destination, create: true)
        defer { destinationDirectory.close() }
        let before = try PrivateDirectoryTree.inventory(sourceDirectory)
        let copied = try PrivateDirectoryTree.copy(from: sourceDirectory, to: destinationDirectory)
        guard before == copied, before == (try PrivateDirectoryTree.inventory(sourceDirectory)) else {
            throw failure(L("scoped archive changed during staging"))
        }
    }

    private static func snapshot(from source: URL, to destination: URL) throws {
        _ = try HostDatabaseRestore.inspect(backupURL: source)
        let fd = open(destination.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure(L("cannot create exclusive SQLite snapshot: %1$@", destination.path)) }
        close(fd)
        try writeSnapshot(from: source, to: destination)
        let result = open(destination.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard result >= 0 else { throw failure(L("cannot open completed SQLite snapshot")) }
        defer { close(result) }
        guard fsync(result) == 0 else { throw failure(L("cannot sync SQLite snapshot")) }
        let parent = try PrivateDirectory(destination.deletingLastPathComponent(), create: false)
        defer { parent.close() }
        try parent.synchronize()
    }

    private static func writeSnapshot(from source: URL, to destination: URL) throws {
        let input = try SQLiteDB(path: source.path, readonly: true)
        let output = try SQLiteDB(path: destination.path)
        try input.backup(to: output)
        try output.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        try output.execute("PRAGMA journal_mode=DELETE;")
    }

    static func create(backupURL: URL, currentURL: URL, appSupport: URL) throws {
        let parent = try PrivateDirectory(backupURL.deletingLastPathComponent(), create: false)
        defer { parent.close() }
        let companion = HostScopedSessionArchive.companionURL(for: backupURL)
        guard try !exists(backupURL.lastPathComponent, in: parent), try !exists(companion.lastPathComponent, in: parent) else {
            throw failure(L("backup destination already exists"))
        }
        let name = ".scoped-backup-\(UUID().uuidString.lowercased())"
        let stage = try child(name, in: parent, create: true)
        defer { stage.close() }
        let stageURL = backupURL.deletingLastPathComponent().appendingPathComponent(name)
        var publishedCompanion = false
        do {
            let database = stageURL.appendingPathComponent("database.sqlite")
            try snapshot(from: currentURL, to: database)
            _ = try HostScopedSessionArchive.capture(databaseURL: database, appSupport: appSupport,
                                                       destination: stageURL.appendingPathComponent("archive"))
            _ = try HostScopedSessionArchive.validate(databaseURL: database, archiveURL: stageURL.appendingPathComponent("archive"))
            try PrivateDirectoryTree.renameChild("archive", from: stage, to: parent, as: companion.lastPathComponent)
            publishedCompanion = true
            try PrivateDirectoryTree.renameChild("database.sqlite", from: stage, to: parent, as: backupURL.lastPathComponent)
        } catch {
            let originalError = error
            if publishedCompanion { try PrivateDirectoryTree.removeChild(companion.lastPathComponent, from: parent) }
            try PrivateDirectoryTree.removeChild(name, from: parent)
            throw originalError
        }
        try PrivateDirectoryTree.removeChild(name, from: parent)
    }

    static func inspect(backupURL: URL) throws -> Review {
        let database = try HostDatabaseRestore.inspect(backupURL: backupURL)
        let parent = try PrivateDirectory(backupURL.deletingLastPathComponent(), create: false)
        defer { parent.close() }
        let companion = HostScopedSessionArchive.companionURL(for: backupURL)
        guard try exists(companion.lastPathComponent, in: parent) else {
            return Review(database: database, fingerprint: database.fingerprint, scopedSessionCount: 0,
                          requiresConfirmation: database.requiresConfirmation)
        }
        let manifest = try HostScopedSessionArchive.validate(databaseURL: backupURL, archiveURL: companion)
        let digest = try HostScopedSessionArchive.manifestDigest(archiveURL: companion)
        let fingerprint = SHA256.hash(data: Data("scoped-session-backup-v1\n\(database.fingerprint)\n\(digest)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return Review(database: database, fingerprint: fingerprint, scopedSessionCount: manifest.sessions.count,
                      requiresConfirmation: true)
    }

    static func restore(backupURL: URL, currentURL: URL, appSupport: URL, reviewToken: String?, quarantineOrphans: Bool = false) throws -> URL {
        let review = try inspect(backupURL: backupURL)
        if review.requiresConfirmation && reviewToken != review.fingerprint {
            throw failure(L("database restore requires the exact inspected review fingerprint"))
        }
        let support = try PrivateDirectory(appSupport, create: false)
        defer { support.close() }
        guard try !exists(journalName, in: support) else { throw failure(L("interrupted scoped restore requires recovery")) }
        let sourceParent = try PrivateDirectory(backupURL.deletingLastPathComponent(), create: false)
        defer { sourceParent.close() }
        let companion = HostScopedSessionArchive.companionURL(for: backupURL)
        if try !exists(companion.lastPathComponent, in: sourceParent) {
            return try HostDatabaseRestore.restore(backupURL: backupURL, currentURL: currentURL, reviewToken: reviewToken,
                quarantineOrphans: quarantineOrphans,
                beforeCommit: { _, recovery in
                    let manifest = try HostScopedSessionArchive.capture(databaseURL: recovery, appSupport: appSupport,
                        destination: HostScopedSessionArchive.companionURL(for: recovery))
                    guard manifest.sessions.isEmpty else {
                        throw failure(L("database-only restore cannot replace scoped native history"))
                    }
                })
        }

        let stageName = ".scoped-restore-\(UUID().uuidString.lowercased())"
        let stage = try child(stageName, in: support, create: true)
        defer { stage.close() }
        let stageURL = appSupport.appendingPathComponent(stageName)
        var journal: Journal?
        var committed = false
        do {
            let incomingDB = stageURL.appendingPathComponent("incoming.sqlite")
            try snapshot(from: backupURL, to: incomingDB)
            let incomingURL = stageURL.appendingPathComponent("incoming")
            try copyDirectory(from: companion, to: incomingURL)
            let incoming = try HostScopedSessionArchive.validate(databaseURL: incomingDB, archiveURL: incomingURL)
            guard try inspectStaged(databaseURL: incomingDB, archiveURL: incomingURL) == review.fingerprint else {
                throw failure(L("backup changed after review"))
            }
            _ = try childAndClose("undo", in: stage)
            let recovery = try HostDatabaseRestore.restore(backupURL: incomingDB, currentURL: currentURL,
                reviewToken: review.database.fingerprint, quarantineOrphans: quarantineOrphans, beforeCommit: { sanitized, recoveryURL in
                    try HostScopedSessionArchive.validateBindings(incoming, databaseURL: sanitized)
                    try HostScopedSessionArchive.requireQuiescent(incoming, appSupport: appSupport)
                    let recoveryArchive = HostScopedSessionArchive.companionURL(for: recoveryURL)
                    let original = try HostScopedSessionArchive.capture(databaseURL: recoveryURL, appSupport: appSupport,
                                                                         destination: recoveryArchive)
                    _ = try HostScopedSessionArchive.validate(databaseURL: recoveryURL, archiveURL: recoveryArchive)
                    try copyDirectory(from: recoveryArchive, to: stageURL.appendingPathComponent("original"))
                    let record = Journal(version: 1, stageName: stageName, currentPath: currentURL.standardizedFileURL.path,
                        recoveryName: recoveryURL.lastPathComponent,
                        stagedFingerprint: try HostDatabaseRestore.inspect(backupURL: sanitized).fingerprint,
                        recoveryFingerprint: try HostDatabaseRestore.inspect(backupURL: recoveryURL).fingerprint,
                        incomingDigest: try HostScopedSessionArchive.manifestDigest(archiveURL: incomingURL),
                        recoveryDigest: try HostScopedSessionArchive.manifestDigest(archiveURL: recoveryArchive),
                        hadBindingsRoot: try exists("bot-context-sessions", in: support), filesReady: false)
                    try stage.synchronize()
                    journal = record
                    try save(record, in: support)
                    try install(incoming: incoming, original: original, stage: stage, support: support)
                    journal!.filesReady = true
                    try save(journal!, in: support)
                }, didCommit: { committed = true })
            guard let record = journal else { throw failure(L("scoped restore did not prepare native files")) }
            try finish(record, currentURL: currentURL, appSupport: appSupport, support: support, stage: stage, committed: true)
            return recovery
        } catch {
            let originalError = error
            if committed {
                throw failure(L("database restore committed; scoped cleanup incomplete: %1$@", originalError))
            }
            if let record = journal, try exists(journalName, in: support) {
                do {
                    try finish(record, currentURL: currentURL, appSupport: appSupport, support: support, stage: stage, committed: false)
                } catch {
                    throw failure(L("scoped restore incomplete; recovery retained: %1$@; original error: %2$@", error, originalError))
                }
            } else {
                try PrivateDirectoryTree.removeChild(stageName, from: support)
            }
            throw originalError
        }
    }

    private static func inspectStaged(databaseURL: URL, archiveURL: URL) throws -> String {
        let database = try HostDatabaseRestore.inspect(backupURL: databaseURL)
        let digest = try HostScopedSessionArchive.manifestDigest(archiveURL: archiveURL)
        return SHA256.hash(data: Data("scoped-session-backup-v1\n\(database.fingerprint)\n\(digest)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func childAndClose(_ name: String, in directory: PrivateDirectory) throws {
        let result = try child(name, in: directory, create: true)
        result.close()
    }

    private static func save(_ journal: Journal, in support: PrivateDirectory) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal)
        try support.writeAtomically(data, to: journalName)
        try support.synchronize()
    }

    private static func home(_ session: HostScopedSessionArchive.Session, support: PrivateDirectory, create: Bool) throws -> PrivateDirectory {
        let guests = try child("bot-guests", in: support, create: create)
        defer { guests.close() }
        let scope = try child(session.storageBotID.value.uuidString.lowercased(), in: guests, create: create)
        defer { scope.close() }
        return try child("home", in: scope, create: create)
    }

    private static func scope(_ session: HostScopedSessionArchive.Session, root: PrivateDirectory, create: Bool) throws -> PrivateDirectory {
        try child(session.storageBotID.value.uuidString.lowercased(), in: root, create: create)
    }

    private static func historyName(_ session: HostScopedSessionArchive.Session) -> String {
        ".distill-context-session-\(session.conversationID.value.uuidString.lowercased())"
    }

    private static func key(_ session: HostScopedSessionArchive.Session) -> String {
        "\(session.storageBotID.value.uuidString.lowercased())/\(session.conversationID.value.uuidString.lowercased())"
    }

    private static func union(_ lhs: HostScopedSessionArchive.Manifest, _ rhs: HostScopedSessionArchive.Manifest) -> [HostScopedSessionArchive.Session] {
        var sessions: [String: HostScopedSessionArchive.Session] = [:]
        for session in lhs.sessions + rhs.sessions { sessions[key(session)] = session }
        return sessions.values.sorted { key($0) < key($1) }
    }

    private static func install(incoming: HostScopedSessionArchive.Manifest, original: HostScopedSessionArchive.Manifest,
                                stage: PrivateDirectory, support: PrivateDirectory) throws {
        let undo = try stage.child("undo", create: false)
        defer { undo.close() }
        let incomingRoot = try stage.child("incoming", create: false)
        defer { incomingRoot.close() }
        let histories = try incomingRoot.child("histories", create: false)
        defer { histories.close() }
        let originals = Dictionary(uniqueKeysWithValues: original.sessions.map { (key($0), $0) })
        let incomingSessions = Dictionary(uniqueKeysWithValues: incoming.sessions.map { (key($0), $0) })
        for session in union(incoming, original) {
            let live = try home(session, support: support, create: true)
            defer { live.close() }
            let name = historyName(session)
            if originals[key(session)]?.hasHistoryHome == true {
                try verifyHistory(originals[key(session)]!, in: live)
                let undoScope = try scope(session, root: undo, create: true)
                defer { undoScope.close() }
                try PrivateDirectoryTree.renameChild(name, from: live, to: undoScope, as: session.conversationID.value.uuidString.lowercased())
            } else if try exists(name, in: live) {
                throw failure(L("unindexed native history appeared during restore"))
            }
            if incomingSessions[key(session)]?.hasHistoryHome == true {
                let source = try scope(session, root: histories, create: false)
                defer { source.close() }
                try PrivateDirectoryTree.renameChild(session.conversationID.value.uuidString.lowercased(), from: source, to: live, as: name)
            }
        }
        if try exists("bot-context-sessions", in: support) {
            try PrivateDirectoryTree.renameChild("bot-context-sessions", from: support, to: undo, as: "bindings")
        }
        try PrivateDirectoryTree.renameChild("bindings", from: incomingRoot, to: support, as: "bot-context-sessions")
    }

    private static func verifyHistory(_ session: HostScopedSessionArchive.Session, in parent: PrivateDirectory) throws {
        let directory = try parent.child(historyName(session), create: false)
        defer { directory.close() }
        guard try PrivateDirectoryTree.inventory(directory, excludingRootNames: excludedHomeNames) == session.history else {
            throw failure(L("native history changed during scoped restore"))
        }
    }

    private static func verifyBindings(at name: String, in parent: PrivateDirectory, archive: PrivateDirectory) throws {
        let directory = try parent.child(name, create: false)
        defer { directory.close() }
        let expected = try archive.child("bindings", create: false)
        defer { expected.close() }
        guard try PrivateDirectoryTree.inventory(directory) == PrivateDirectoryTree.inventory(expected) else {
            throw failure(L("scoped binding tree changed during restore"))
        }
    }

    private static func finish(_ journal: Journal, currentURL: URL, appSupport: URL, support: PrivateDirectory,
                               stage: PrivateDirectory, committed: Bool) throws {
        let stageURL = appSupport.appendingPathComponent(journal.stageName)
        let incomingURL = stageURL.appendingPathComponent("incoming")
        let originalURL = stageURL.appendingPathComponent("original")
        let recoveryURL = currentURL.deletingLastPathComponent().appendingPathComponent(journal.recoveryName)
        let recoveryArchive = HostScopedSessionArchive.companionURL(for: recoveryURL)
        guard try HostScopedSessionArchive.manifestDigest(archiveURL: incomingURL) == journal.incomingDigest,
              try HostScopedSessionArchive.manifestDigest(archiveURL: originalURL) == journal.recoveryDigest,
              try HostScopedSessionArchive.manifestDigest(archiveURL: recoveryArchive) == journal.recoveryDigest else {
            throw failure(L("scoped restore recovery manifest changed"))
        }
        if !committed {
            var rollback = journal
            rollback.filesReady = false
            try save(rollback, in: support)
        }
        // The immutable recovery copy must be intact before undo data can be removed.
        let original = try HostScopedSessionArchive.validate(databaseURL: recoveryURL, archiveURL: recoveryArchive)
        let incomingDataRoot = try stage.child("incoming", create: false)
        defer { incomingDataRoot.close() }
        let originalDataRoot = try stage.child("original", create: false)
        defer { originalDataRoot.close() }
        let incomingData = try PrivateDirectoryTree.readFile("manifest.json", in: incomingDataRoot, maximumBytes: 64 * 1_024 * 1_024)
        let incoming = try JSONDecoder().decode(HostScopedSessionArchive.Manifest.self, from: incomingData)
        let incomingDatabase = stageURL.appendingPathComponent("incoming.sqlite")
        guard incoming.version == 1,
              Set(incoming.sessions.map { key($0) }).count == incoming.sessions.count,
              incoming.databaseFingerprint == (try HostDatabaseRestore.inspect(backupURL: incomingDatabase).fingerprint) else {
            throw failure(L("invalid staged incoming manifest"))
        }
        try HostScopedSessionArchive.validateBindings(incoming, databaseURL: incomingDatabase)
        guard try HostDatabaseRestore.inspect(backupURL: currentURL).fingerprint == (committed ? journal.stagedFingerprint : journal.recoveryFingerprint) else {
            throw failure(L("SQLite state changed during scoped restore recovery"))
        }
        let undo = try stage.child("undo", create: false)
        defer { undo.close() }
        let originals = Dictionary(uniqueKeysWithValues: original.sessions.map { (key($0), $0) })
        let incomingSessions = Dictionary(uniqueKeysWithValues: incoming.sessions.map { (key($0), $0) })
        for session in union(incoming, original) {
            let live = try home(session, support: support, create: true)
            defer { live.close() }
            let name = historyName(session)
            if committed {
                if let expected = incomingSessions[key(session)], expected.hasHistoryHome {
                    try verifyHistory(expected, in: live)
                } else if try exists(name, in: live) { throw failure(L("unexpected native home after restore commit")) }
                try live.synchronize()
                continue
            }
            let undoScope = try scope(session, root: undo, create: true)
            defer { undoScope.close() }
            let cid = session.conversationID.value.uuidString.lowercased()
            if try exists(cid, in: undoScope) {
                guard originals[key(session)]?.hasHistoryHome == true else { throw failure(L("unexpected restore undo home")) }
                if try exists(name, in: live) {
                    guard let expected = incomingSessions[key(session)], expected.hasHistoryHome else { throw failure(L("unexpected installed home")) }
                    try verifyHistory(expected, in: live)
                    try PrivateDirectoryTree.renameChild(name, from: live, to: undoScope, as: "discard-" + cid)
                }
                try PrivateDirectoryTree.renameChild(cid, from: undoScope, to: live, as: name)
                try verifyHistory(originals[key(session)]!, in: live)
            } else if let expected = originals[key(session)], expected.hasHistoryHome {
                try verifyHistory(expected, in: live)
            } else if try exists(name, in: live) {
                guard let expected = incomingSessions[key(session)], expected.hasHistoryHome else { throw failure(L("unexpected new native home")) }
                try verifyHistory(expected, in: live)
                try PrivateDirectoryTree.renameChild(name, from: live, to: undoScope, as: "discard-" + cid)
            }
            try live.synchronize()
            try undoScope.synchronize()
        }
        try undo.synchronize()
        if committed {
            try verifyInstalledBindings(incoming, support: support)
        } else if try exists("bindings", in: undo) {
            if try exists("bot-context-sessions", in: support) {
                try verifyInstalledBindings(incoming, support: support)
                try PrivateDirectoryTree.renameChild("bot-context-sessions", from: support, to: undo, as: "discard-bindings")
            }
            try PrivateDirectoryTree.renameChild("bindings", from: undo, to: support, as: "bot-context-sessions")
            try verifyBindings(at: "bot-context-sessions", in: support, archive: originalDataRoot)
        } else if journal.hadBindingsRoot {
            try verifyBindings(at: "bot-context-sessions", in: support, archive: originalDataRoot)
        } else if try exists("bot-context-sessions", in: support) {
            try verifyInstalledBindings(incoming, support: support)
            try PrivateDirectoryTree.renameChild("bot-context-sessions", from: support, to: undo, as: "discard-bindings")
        }
        try undo.synchronize()
        try stage.synchronize()
        try support.synchronize()
        // Keep the stage until the durable journal is removed, so recovery is idempotent.
        try PrivateDirectoryTree.removeChild(journalName, from: support)
        try PrivateDirectoryTree.removeChild(journal.stageName, from: support)
    }

    private static func verifyInstalledBindings(_ manifest: HostScopedSessionArchive.Manifest, support: PrivateDirectory) throws {
        let root = try support.child("bot-context-sessions", create: false)
        defer { root.close() }
        var expected: [PrivateDirectoryTree.Entry] = []
        var scopes = Set<String>()
        for session in manifest.sessions {
            let sid = session.storageBotID.value.uuidString.lowercased()
            scopes.insert(sid)
            let directory = try root.child(sid, create: false)
            defer { directory.close() }
            let name = session.conversationID.value.uuidString.lowercased() + ".json"
            let bytes = try PrivateDirectoryTree.readFile(name, in: directory, maximumBytes: 1_024 * 1_024)
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard hash == session.bindingSHA256 else { throw failure(L("installed binding changed")) }
            expected.append(.init(path: sid + "/" + name, isDirectory: false, byteCount: Int64(bytes.count), sha256: hash))
        }
        expected += scopes.map { .init(path: $0, isDirectory: true, byteCount: 0, sha256: nil) }
        guard try PrivateDirectoryTree.inventory(root) == expected.sorted(by: { $0.path < $1.path }) else {
            throw failure(L("unexpected installed binding entries"))
        }
    }

    static func recoverInterruptedRestore(currentURL: URL, appSupport: URL) throws {
        let support = try PrivateDirectory(appSupport, create: false)
        defer { support.close() }
        guard try exists(journalName, in: support) else { return }
        let bytes = try PrivateDirectoryTree.readFile(journalName, in: support, maximumBytes: 1_024 * 1_024)
        let journal = try JSONDecoder().decode(Journal.self, from: bytes)
        let token = String(journal.stageName.dropFirst(".scoped-restore-".count))
        let recoveryToken = String(journal.recoveryName.dropFirst(".restore-recovery-".count).dropLast(".sqlite".count))
        guard journal.version == 1, journal.stageName == ".scoped-restore-" + token,
              UUID(uuidString: token)?.uuidString.lowercased() == token,
              journal.recoveryName == ".restore-recovery-" + recoveryToken + ".sqlite",
              UUID(uuidString: recoveryToken) != nil,
              journal.currentPath == currentURL.standardizedFileURL.path else {
            throw failure(L("invalid scoped restore recovery journal"))
        }
        let fingerprint = try HostDatabaseRestore.inspect(backupURL: currentURL).fingerprint
        let committed = journal.filesReady && fingerprint == journal.stagedFingerprint
        guard committed || fingerprint == journal.recoveryFingerprint else {
            throw failure(L("unknown SQLite state; scoped restore recovery retained"))
        }
        let stage = try support.child(journal.stageName, create: false)
        defer { stage.close() }
        try finish(journal, currentURL: currentURL, appSupport: appSupport, support: support, stage: stage, committed: committed)
    }
}
