import CryptoKit
import Foundation
import AgentRuntime
import CoreModel
import Persistence

internal enum HostScopedSessionArchive {
    internal struct Session: Codable, Equatable {
        let storageBotID: BotID
        let conversationID: BotConversationID
        let binding: BotContextSessionStore.Binding
        let bindingSHA256: String
        let hasHistoryHome: Bool
        let history: [PrivateDirectoryTree.Entry]
    }

    internal struct Manifest: Codable, Equatable {
        let version: Int
        let databaseFingerprint: String
        let sessions: [Session]

        init(version: Int = 1, databaseFingerprint: String, sessions: [Session]) {
            self.version = version
            self.databaseFingerprint = databaseFingerprint
            self.sessions = sessions
        }
    }

    private static let maximumManifestBytes = 64 * 1_024 * 1_024
    private static let maximumEntries = 100_000
    private static let credentialNames: Set<String> = [
        "config.toml", "auth.json", "claude-auth.json", "codex-auth.json",
        "openrouter-auth.json", "accounts", ".env", ".mcp.json"
    ]
    private static let excludedHomeNames: Set<String> = [
        "config.toml", "auth.json", "claude-auth.json", "codex-auth.json",
        "openrouter-auth.json", "accounts", ".env", ".mcp.json", ".DS_Store"
    ]

    static func companionURL(for databaseURL: URL) -> URL {
        databaseURL.appendingPathExtension("scoped-sessions")
    }

    static func capture(databaseURL: URL, appSupport: URL, destination: URL) throws -> Manifest {
        guard mkdir(destination.path, 0o700) == 0 else { throw failure(L("cannot create new scoped archive destination")) }
        let root = try PrivateDirectory(destination, create: false)
        defer { root.close() }
        guard try PrivateDirectoryTree.childNames(root).isEmpty else { throw failure(L("archive destination is not empty")) }
        try requireNoPendingRecovery(appSupport: appSupport)

        let fingerprint = try HostDatabaseRestore.inspect(backupURL: databaseURL).fingerprint
        let sourceSupport = try PrivateDirectory(appSupport, create: false)
        defer { sourceSupport.close() }
        let bindingsRoot = try openOptionalChild(sourceSupport, "bot-context-sessions")
        defer { bindingsRoot?.close() }
        let archiveBindings = try root.child("bindings", create: true)
        defer { archiveBindings.close() }
        let archiveHistories = try root.child("histories", create: true)
        defer { archiveHistories.close() }
        var sessions: [Session] = []
        if let bindingsRoot {
            for storageName in try PrivateDirectoryTree.childNames(bindingsRoot).sorted() {
                guard let storageUUID = UUID(uuidString: storageName), storageName == storageUUID.uuidString.lowercased() else {
                    throw failure(L("noncanonical scoped binding storage ID: %1$@", storageName))
                }
                let scope = try bindingsRoot.child(storageName, create: false)
                defer { scope.close() }
                for filename in try PrivateDirectoryTree.childNames(scope).sorted() {
                    guard filename.hasSuffix(".json"),
                          let conversationUUID = UUID(uuidString: String(filename.dropLast(5))),
                          filename == conversationUUID.uuidString.lowercased() + ".json" else {
                        throw failure(L("invalid scoped binding filename: %1$@", filename))
                    }
                    let bytes = try PrivateDirectoryTree.readFile(filename, in: scope, maximumBytes: maximumManifestBytes)
                    let binding = try JSONDecoder().decode(BotContextSessionStore.Binding.self, from: bytes)
                    guard binding.version == 1,
                          binding.pin.conversationID.value == conversationUUID,
                          try storageID(for: binding.pin, virtualMachineID: binding.virtualMachineID) == BotID(storageUUID) else {
                        throw failure(L("scoped binding identity mismatch: %1$@", filename))
                    }
                    try requireQuiescent(Manifest(databaseFingerprint: fingerprint, sessions: [
                        Session(storageBotID: BotID(storageUUID), conversationID: BotConversationID(conversationUUID), binding: binding, bindingSHA256: digest(bytes), hasHistoryHome: false, history: [])
                    ]), appSupport: appSupport)
                    let home = try openGuestHome(storageName, support: sourceSupport)
                    defer { home?.close() }
                    var hasHistoryHome = false
                    var history: [PrivateDirectoryTree.Entry] = []
                    if let home {
                        let name = BotContextSessionStore.directoryName(pin: binding.pin)
                        let sessionHome = try openOptionalChild(home, name)
                        if let sessionHome {
                            defer { sessionHome.close() }
                            hasHistoryHome = true
                            let botHistory = try createOrOpenChild(archiveHistories, storageName)
                            defer { botHistory.close() }
                            let target = try botHistory.child(conversationUUID.uuidString.lowercased(), create: true)
                            defer { target.close() }
                            let before = try PrivateDirectoryTree.inventory(sessionHome, excludingRootNames: excludedHomeNames)
                            let entries = try PrivateDirectoryTree.copy(from: sessionHome, to: target, excludingRootNames: excludedHomeNames)
                            let after = try PrivateDirectoryTree.inventory(sessionHome, excludingRootNames: excludedHomeNames)
                            guard before == after, entries == before else { throw failure(L("native scoped history changed during capture")) }
                            history = entries
                        }
                    }
                    if !hasHistoryHome && binding.providerSessionID != nil {
                        throw failure(L("bound scoped session has no native history home"))
                    }
                    let bindingScope = try createOrOpenChild(archiveBindings, storageName)
                    defer { bindingScope.close() }
                    try PrivateDirectoryTree.writeFile(filename, data: bytes, in: bindingScope)
                    guard try PrivateDirectoryTree.readFile(filename, in: scope, maximumBytes: maximumManifestBytes) == bytes else {
                        throw failure(L("native scoped binding changed during capture"))
                    }
                    sessions.append(Session(storageBotID: BotID(storageUUID), conversationID: BotConversationID(conversationUUID), binding: binding, bindingSHA256: digest(bytes), hasHistoryHome: hasHistoryHome, history: history))
                }
            }
        }
        guard sessions.count <= maximumEntries else { throw failure(L("too many scoped sessions")) }
        sessions.sort(by: sessionOrder)
        let manifest = Manifest(databaseFingerprint: fingerprint, sessions: sessions)
        try validateBindings(manifest, databaseURL: databaseURL)
        try requireQuiescent(manifest, appSupport: appSupport)
        try rejectOrphanHistories(manifest, appSupport: appSupport)
        let bytes = try encoder().encode(manifest)
        guard bytes.count <= maximumManifestBytes else { throw failure(L("scoped archive manifest exceeds size limit")) }
        try PrivateDirectoryTree.writeFile("manifest.json", data: bytes, in: root)
        try synchronizeDirectories(root)
        let destinationParent = try PrivateDirectory(destination.deletingLastPathComponent(), create: false)
        defer { destinationParent.close() }
        try destinationParent.synchronize()
        let manifestInventory = try PrivateDirectoryTree.inventory(root)
        guard manifestInventory.count <= maximumEntries else { throw failure(L("scoped archive has too many entries")) }
        return try validate(databaseURL: databaseURL, archiveURL: destination)
    }

    static func validate(databaseURL: URL, archiveURL: URL) throws -> Manifest {
        let archive = try PrivateDirectory(archiveURL, create: false)
        defer { archive.close() }
        let data = try PrivateDirectoryTree.readFile("manifest.json", in: archive, maximumBytes: maximumManifestBytes)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.version == 1,
              manifest.sessions.count <= maximumEntries,
              manifest.sessions == manifest.sessions.sorted(by: sessionOrder),
              manifest.databaseFingerprint == (try HostDatabaseRestore.inspect(backupURL: databaseURL).fingerprint) else {
            throw failure(L("scoped archive manifest or database fingerprint mismatch"))
        }
        var expected: [PrivateDirectoryTree.Entry] = [
            PrivateDirectoryTree.Entry(path: "manifest.json", isDirectory: false, byteCount: Int64(data.count), sha256: digest(data)),
            PrivateDirectoryTree.Entry(path: "bindings", isDirectory: true, byteCount: 0, sha256: nil),
            PrivateDirectoryTree.Entry(path: "histories", isDirectory: true, byteCount: 0, sha256: nil)
        ]
        var seen = Set<String>()
        for session in manifest.sessions {
            let storage = session.storageBotID.value.uuidString.lowercased()
            let cid = session.conversationID.value.uuidString.lowercased()
            guard cid == session.binding.pin.conversationID.value.uuidString.lowercased(),
                  session.binding.pin.conversationID == session.conversationID,
                  try storageID(for: session.binding.pin, virtualMachineID: session.binding.virtualMachineID) == session.storageBotID,
                  session.binding.version == 1,
                  session.binding.cwd.hasPrefix("/"),
                  URL(fileURLWithPath: session.binding.cwd).standardizedFileURL.path == session.binding.cwd,
                  session.binding.cwd.utf8.count <= 16_384,
                  !session.binding.cwd.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  session.binding.providerSessionID.map(isCanonicalSessionID) ?? true,
                  seen.insert(storage + "/" + cid).inserted else { throw failure(L("invalid or duplicate scoped session identity")) }
            let bindingPath = "bindings/\(storage)/\(cid).json"
            let bindingDir = try archive.child("bindings", create: false)
            defer { bindingDir.close() }
            let scope = try bindingDir.child(storage, create: false)
            defer { scope.close() }
            let bindingBytes = try PrivateDirectoryTree.readFile(cid + ".json", in: scope, maximumBytes: maximumManifestBytes)
            guard digest(bindingBytes) == session.bindingSHA256,
                  try JSONDecoder().decode(BotContextSessionStore.Binding.self, from: bindingBytes) == session.binding else {
                throw failure(L("scoped binding bytes do not match manifest"))
            }
            expected += [
                PrivateDirectoryTree.Entry(path: "bindings/\(storage)", isDirectory: true, byteCount: 0, sha256: nil),
                PrivateDirectoryTree.Entry(path: bindingPath, isDirectory: false, byteCount: Int64(bindingBytes.count), sha256: digest(bindingBytes))
            ]
            if session.hasHistoryHome {
                let prefix = "histories/\(storage)/\(cid)"
                expected += [
                    PrivateDirectoryTree.Entry(path: "histories", isDirectory: true, byteCount: 0, sha256: nil),
                    PrivateDirectoryTree.Entry(path: "histories/\(storage)", isDirectory: true, byteCount: 0, sha256: nil),
                    PrivateDirectoryTree.Entry(path: prefix, isDirectory: true, byteCount: 0, sha256: nil)
                ]
                let sortedHistory = session.history.sorted { $0.path < $1.path }
                guard session.history == sortedHistory,
                      Set(session.history.map(\.path)).count == session.history.count,
                      !session.history.contains(where: { $0.path.hasPrefix("/") || $0.path.split(separator: "/").contains("..") }),
                      session.history.allSatisfy({ !$0.path.isEmpty && !$0.path.split(separator: "/").contains(where: { $0.isEmpty || $0 == "." }) }) else { throw failure("invalid scoped history path") }
                expected += session.history.map {
                    PrivateDirectoryTree.Entry(path: "\(prefix)/\($0.path)", isDirectory: $0.isDirectory, byteCount: $0.byteCount, sha256: $0.sha256)
                }
            } else if !session.history.isEmpty || session.binding.providerSessionID != nil {
                throw failure(L("missing history home for scoped cursor"))
            }
        }
        expected = deduplicated(expected)
        let actual = try PrivateDirectoryTree.inventory(archive)
        guard actual == expected.sorted(by: { $0.path < $1.path }) else { throw failure(L("scoped archive inventory mismatch")) }
        try rejectCredentialEntries(actual)
        try validateBindings(manifest, databaseURL: databaseURL)
        return manifest
    }

    static func manifestDigest(archiveURL: URL) throws -> String {
        let archive = try PrivateDirectory(archiveURL, create: false)
        defer { archive.close() }
        return digest(try PrivateDirectoryTree.readFile("manifest.json", in: archive, maximumBytes: maximumManifestBytes))
    }

    static func validateBindings(_ manifest: Manifest, databaseURL: URL) throws {
        let db = try SQLiteDB(path: databaseURL.path, readonly: true)
        let botStore = BotStore(db: db)
        let threads = AgentThreadRepository(db: db)
        let columns = try db.prepare("PRAGMA table_info(agent_threads);")
        defer { columns.reset() }
        var hasDestination = false
        while try columns.step() {
            if columns.columnText(1) == "execution_destination" { hasDestination = true }
        }
        for session in manifest.sessions {
            let binding = session.binding
            let pin = binding.pin
            let resourceID = try hasDestination
                ? botStore.contextRuntimeIdentity(pin: pin, threadID: binding.threadID).storageBotID
                : storageID(for: pin, virtualMachineID: nil)
            guard try botStore.conversationContextPin(conversationID: session.conversationID) == pin,
                  let conversation = try botStore.conversation(id: session.conversationID),
                  conversation.botID == pin.botID,
                  conversation.linkedAgentThreadID == binding.threadID,
                  let thread = try threads.get(id: binding.threadID),
                  thread.provider == .distill,
                  thread.actor == .bot(pin.botID),
                  thread.actorLockedAt != nil,
                  thread.executionTarget == .vm,
                  thread.workspaceId == workspaceID(for: pin.context),
                  try threads.guestPlacement(of: binding.threadID)?.guestRuntime == BotGuestRuntime.distillV1,
                  resourceID == session.storageBotID,
                  pin.conversationID == session.conversationID else {
                throw failure(L("scoped binding does not match canonical database conversation/thread/pin"))
            }
        }
    }

    static func requireQuiescent(_ manifest: Manifest, appSupport: URL) throws {
        guard !manifest.sessions.isEmpty else { return }
        let docker = BotComputerDockerCLI()
        let dockerInfo = try docker.info()
        guard !dockerInfo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure(L("Docker info returned no readable data"))
        }
        let supportPath = appSupport.standardizedFileURL.resolvingSymlinksInPath().path
        for storageBotID in Set(manifest.sessions.map(\.storageBotID)) {
            let name = BotComputerGuestSpec.containerName(botID: storageBotID)
            do {
                guard try docker.containerExists(name: name) else { continue }
                let inspect = try docker.inspect(name: name)
                let ownHome = BotComputerGuestSpec.guestHomeURL(appSupport: appSupport, botID: storageBotID).standardizedFileURL.resolvingSymlinksInPath().path
                if inspect.running, let source = inspect.homeSource,
                   URL(fileURLWithPath: source).standardizedFileURL.resolvingSymlinksInPath().path == ownHome,
                   ownHome.hasPrefix(supportPath + "/") {
                    throw failure(L("scoped bot container is running: %1$@", name))
                }
            } catch BotComputerGuestError.notReady {
                continue
            }
        }
    }

    private static func rejectOrphanHistories(_ manifest: Manifest, appSupport: URL) throws {
        let indexed = Set(manifest.sessions.map { "\($0.storageBotID.value.uuidString.lowercased())/\(BotContextSessionStore.directoryName(pin: $0.binding.pin))" })
        let support = try PrivateDirectory(appSupport, create: false)
        defer { support.close() }
        guard let guests = try openOptionalChild(support, "bot-guests") else { return }
        defer { guests.close() }
        for botName in try PrivateDirectoryTree.childNames(guests) {
            if botName == ".DS_Store" { continue }
            guard let id = UUID(uuidString: botName), botName == id.uuidString.lowercased() else {
                throw failure(L("noncanonical guest-home storage ID: %1$@", botName))
            }
            let bot = try guests.child(botName, create: false)
            defer { bot.close() }
            guard let home = try openOptionalChild(bot, "home") else { continue }
            defer { home.close() }
            for name in try PrivateDirectoryTree.childNames(home) where name.hasPrefix(".distill-context-session-") {
                guard indexed.contains("\(botName)/\(name)") else { throw failure("unindexed native scoped history: \(botName)/\(name)") }
            }
        }
    }

    private static func rejectCredentialEntries(_ entries: [PrivateDirectoryTree.Entry]) throws {
        for entry in entries {
            let parts = entry.path.split(separator: "/")
            guard parts.count >= 4, parts[0] == "histories",
                  credentialNames.contains(String(parts[3])) else { continue }
            throw failure(L("forbidden credential entry in scoped archive"))
        }
    }

    private static func requireNoPendingRecovery(appSupport: URL) throws {
        let support = try PrivateDirectory(appSupport, create: false)
        defer { support.close() }
        let names = try PrivateDirectoryTree.childNames(support)
        guard !names.contains(where: { $0.hasPrefix(".distill-context-recovery") || $0 == ".scoped-session-restore.json" }) else {
            throw failure(L("pending contextual recovery journal prevents scoped archive capture"))
        }
        guard let runs = try openOptionalChild(support, "guest-runs") else { return }
        defer { runs.close() }
        for scopeName in try PrivateDirectoryTree.childNames(runs) {
            if scopeName == ".DS_Store" { continue }
            guard let scopeID = UUID(uuidString: scopeName), scopeName == scopeID.uuidString.lowercased() else {
                throw failure(L("unrecognized contextual recovery entry: %1$@", scopeName))
            }
            let scope = try runs.child(scopeName, create: false)
            defer { scope.close() }
            for name in try PrivateDirectoryTree.childNames(scope) where name.hasSuffix(".context.json") {
                let bytes = try PrivateDirectoryTree.readFile(name, in: scope, maximumBytes: 1_024 * 1_024)
                let record = try JSONDecoder().decode(BotContextGuestRecovery.Record.self, from: bytes)
                guard record.state == .ended else { throw failure(L("pending contextual recovery record prevents scoped archive capture")) }
            }
        }
    }

    private static func storageID(for pin: BotConversationContextPin, virtualMachineID: UUID?) throws -> BotID {
        try BotContextRuntimeIdentity(hostID: pin.hostID, botID: pin.botID, context: pin.context, policyRevision: pin.policyRevision, virtualMachineID: virtualMachineID).storageBotID
    }

    private static func workspaceID(for context: BotContext) -> WorkspaceID? {
        if case .workspace(let id) = context { return id }
        return nil
    }

    private static func sessionOrder(_ lhs: Session, _ rhs: Session) -> Bool {
        let left = lhs.storageBotID.value.uuidString.lowercased() + "/" + lhs.conversationID.value.uuidString.lowercased()
        let right = rhs.storageBotID.value.uuidString.lowercased() + "/" + rhs.conversationID.value.uuidString.lowercased()
        return left < right
    }

    private static func deduplicated(_ entries: [PrivateDirectoryTree.Entry]) -> [PrivateDirectoryTree.Entry] {
        var byPath: [String: PrivateDirectoryTree.Entry] = [:]
        for entry in entries { byPath[entry.path] = entry }
        return Array(byPath.values)
    }

    private static func createOrOpenChild(_ directory: PrivateDirectory, _ name: String) throws -> PrivateDirectory {
        let existing = try PrivateDirectoryTree.childNames(directory).contains(name)
        return try directory.child(name, create: !existing)
    }

    private static func isCanonicalSessionID(_ value: String) -> Bool {
        !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines) && value.utf8.count <= 512 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func openOptionalChild(_ directory: PrivateDirectory, _ name: String) throws -> PrivateDirectory? {
        do { return try directory.child(name, create: false) }
        catch DistillGuestCredentialError.writeFailed(_, let code) where code == ENOENT { return nil }
    }

    private static func openGuestHome(_ storageName: String, support: PrivateDirectory) throws -> PrivateDirectory? {
        guard let guests = try openOptionalChild(support, "bot-guests") else { return nil }
        defer { guests.close() }
        guard let scope = try openOptionalChild(guests, storageName) else { return nil }
        defer { scope.close() }
        return try openOptionalChild(scope, "home")
    }

    private static func createChild(_ directory: PrivateDirectory, _ name: String, create: Bool) throws -> PrivateDirectory {
        try directory.child(name, create: create)
    }

    private static func synchronizeDirectories(_ root: PrivateDirectory) throws {
        let directories = try PrivateDirectoryTree.inventory(root).filter(\.isDirectory).map(\.path).sorted {
            $0.split(separator: "/").count > $1.split(separator: "/").count
        }
        for path in directories {
            var current = root
            var opened: [PrivateDirectory] = []
            defer { opened.forEach { $0.close() } }
            for component in path.split(separator: "/").map(String.init) {
                let next = try current.child(component, create: false)
                opened.append(next)
                current = next
            }
            try current.synchronize()
        }
        try root.synchronize()
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "HostScopedSessionArchive", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
