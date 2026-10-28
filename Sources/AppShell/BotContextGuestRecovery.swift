import Foundation
import AgentRuntime
import CoreModel

struct BotContextGuestRecovery {
    struct Record: Codable {
        var identity: BotContextRuntimeIdentity? { try? BotContextRuntimeIdentity(hostID: hostID, botID: botID, context: context, policyRevision: policyRevision, virtualMachineID: virtualMachineID) }
        let version: Int
        let hostID: String
        let botID: BotID
        let context: BotContext
        let policyRevision: Int64
        let runID: AgentRunID
        var virtualMachineID: UUID? = nil
        var conversationID: BotConversationID? = nil
        var state: State
        enum State: String, Codable { case pending, ended }
    }
    struct Report { let reconciled: [String]; let failures: [String: String] }

    /// `liveRunIDs`: other runs of this identity live in this process; their
    /// pending records and environments are not residue.
    static func begin(identity: BotContextRuntimeIdentity, runID: AgentRunID, conversationID: BotConversationID? = nil,
                      appSupport: URL, liveRunIDs: Set<AgentRunID> = []) throws {
        let directory = try scope(identity: identity, appSupport: appSupport, create: true)
        defer { directory.close() }
        let name = filename(runID)
        let entries = try directory.entriesChecked()
        guard !entries.contains(name) else { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
        for entry in entries where entry.hasSuffix(".context.json") {
            guard let data = directory.read(entry), let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.version == 1, let recordedIdentity = record.identity,
                  recordedIdentity.storageBotID == identity.storageBotID, filename(record.runID) == entry,
                  record.state == .ended || liveRunIDs.contains(record.runID) else {
                throw BotComputerGuestServiceError.contextualRuntimeUnavailable
            }
        }
        let liveEnvironments = Set(liveRunIDs.map { "\($0.value.uuidString.lowercased()).env" })
        guard !entries.contains(where: { $0.hasSuffix(".env") && !liveEnvironments.contains($0) }) else {
            throw BotComputerGuestServiceError.contextualRuntimeUnavailable
        }
        let record = Record(version: 1, hostID: identity.hostID, botID: identity.botID, context: identity.context, policyRevision: identity.policyRevision, runID: runID, virtualMachineID: identity.virtualMachineID, conversationID: conversationID, state: .pending)
        try directory.writeAtomically(JSONEncoder().encode(record), to: name)
        try directory.synchronize()
    }

    static func end(identity: BotContextRuntimeIdentity, runID: AgentRunID, appSupport: URL) throws {
        let directory = try scope(identity: identity, appSupport: appSupport, create: false)
        defer { directory.close() }
        let name = filename(runID)
        guard let data = directory.read(name), var record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == 1, let recordedIdentity = record.identity, recordedIdentity == identity,
              filename(record.runID) == name else {
            throw BotComputerGuestServiceError.contextualRuntimeUnavailable
        }
        if record.state == .ended { return }
        record.state = .ended
        try directory.writeAtomically(JSONEncoder().encode(record), to: name)
        try directory.synchronize()
    }

    static func reconcile(docker: (any BotComputerDockerClienting)?, appSupport: URL,
                          selectedScopes: Set<String>? = nil) -> Report {
        var reconciled: [String] = []
        var failures: [String: String] = [:]
        let runsURL = DistillGuestEnvironment.runsDirectory(appSupport: appSupport)
        let root: PrivateDirectory
        do { root = try PrivateDirectory(runsURL, create: false) }
        catch let error as DistillGuestCredentialError {
            if case .writeFailed(_, ENOENT) = error { return Report(reconciled: [], failures: [:]) }
            return Report(reconciled: [], failures: ["guest-runs": error.localizedDescription])
        } catch { return Report(reconciled: [], failures: ["guest-runs": String(describing: error)]) }
        defer { root.close() }
        let scopes: [String]
        do { scopes = try root.entriesChecked() }
        catch { return Report(reconciled: [], failures: ["guest-runs": String(describing: error)]) }
        for scopeName in scopes {
            if let selectedScopes, !selectedScopes.contains(scopeName) { continue }
            guard let uuid = UUID(uuidString: scopeName), uuid.uuidString.lowercased() == scopeName else {
                if !scopeName.hasSuffix(".env"), scopeName != ".DS_Store" {
                    failures[scopeName] = "Unrecognized contextual recovery entry."
                }
                continue
            }
            do {
                let directory = try root.child(scopeName, create: false)
                defer { directory.close() }
                let entries = try directory.entriesChecked()
                let recordNames = entries.filter { $0.hasSuffix(".context.json") }
                if recordNames.isEmpty {
                    guard !entries.contains(where: { $0.hasSuffix(".env") }) else {
                        throw BotComputerGuestServiceError.contextualRuntimeUnavailable
                    }
                    continue
                }
                var records: [(String, Record, BotContextRuntimeIdentity)] = []
                for name in recordNames {
                    guard let data = directory.read(name), let record = try? JSONDecoder().decode(Record.self, from: data),
                          record.version == 1, let identity = record.identity,
                          identity.storageBotID.value.uuidString.lowercased() == scopeName,
                          filename(record.runID) == name else {
                        throw BotComputerGuestServiceError.contextualRuntimeUnavailable
                    }
                    records.append((name, record, identity))
                }
                let expectedEnv = Set(records.map { $0.1.runID.value.uuidString.lowercased() + ".env" })
                let unexpectedEnv = entries.filter { $0.hasSuffix(".env") && !expectedEnv.contains($0) }
                guard unexpectedEnv.isEmpty else { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
                // Completed shared runs have already removed their credentials.
                // The VM may since have been reused with an ordinary network policy.
                if records.allSatisfy({ $0.1.state == .ended && $0.2.virtualMachineID != nil }),
                   !entries.contains(where: { $0.hasSuffix(".env") }) {
                    reconciled.append(scopeName)
                    continue
                }
                guard let docker else { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
                let service = BotComputerGuestService(appSupport: appSupport, docker: docker, recipeContext: nil)
                try service.stopForContextRecovery(identity: records[0].2)
                for (_, record, identity) in records {
                    let env = record.runID.value.uuidString.lowercased() + ".env"
                    if entries.contains(env), !directory.remove(env) {
                        throw BotComputerGuestServiceError.contextualRuntimeUnavailable
                    }
                    do {
                        let home = try nativeHome(identity: identity, appSupport: appSupport)
                        defer { home.close() }
                        if let conversationID = record.conversationID {
                            let generated = ".distill-context-session-\(conversationID.value.uuidString.lowercased())"
                            let entries = try home.entriesChecked()
                            if entries.contains(generated) {
                                let sessionHome = try home.child(generated, create: false)
                                defer { sessionHome.close() }
                                if (try sessionHome.entriesChecked()).contains("config.toml") {
                                    guard sessionHome.remove("config.toml") else { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
                                    try sessionHome.synchronize()
                                }
                            }
                        } else {
                            let generated = ".distill-context-\(record.runID.value.uuidString.lowercased())"
                            home.removeTree(generated)
                            guard !(try home.entriesChecked()).contains(generated) else {
                                throw BotComputerGuestServiceError.contextualRuntimeUnavailable
                            }
                        }
                        try home.synchronize()
                    } catch let error as DistillGuestCredentialError {
                        if case .writeFailed(_, ENOENT) = error { continue }
                        throw error
                    }
                }
                for (name, var record, _) in records where record.state == .pending {
                    record.state = .ended
                    try directory.writeAtomically(JSONEncoder().encode(record), to: name)
                    try directory.synchronize()
                }
                reconciled.append(scopeName)
            } catch { failures[scopeName] = String(describing: error) }
        }
        return Report(reconciled: reconciled, failures: failures)
    }

    private static func nativeHome(identity: BotContextRuntimeIdentity, appSupport: URL) throws -> PrivateDirectory {
        let support = try PrivateDirectory(appSupport, create: false)
        defer { support.close() }
        let guests = try support.child("bot-guests", create: false)
        defer { guests.close() }
        let guest = try guests.child(identity.storageBotID.value.uuidString.lowercased(), create: false)
        defer { guest.close() }
        return try guest.child("home", create: false)
    }

    private static func scope(identity: BotContextRuntimeIdentity, appSupport: URL, create: Bool) throws -> PrivateDirectory {
        let rootURL = DistillGuestEnvironment.runsDirectory(appSupport: appSupport)
        if create {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let supportParent = try PrivateDirectory(appSupport.deletingLastPathComponent(), create: false)
            defer { supportParent.close() }
            try supportParent.synchronize()
            let support = try PrivateDirectory(appSupport, create: false)
            defer { support.close() }
            try support.synchronize()
        }
        let root = try PrivateDirectory(rootURL, create: false)
        defer { root.close() }
        let child = try root.child(identity.storageBotID.value.uuidString.lowercased(), create: create)
        do {
            if create { try root.synchronize() }
            return child
        } catch {
            child.close()
            throw error
        }
    }
    private static func filename(_ runID: AgentRunID) -> String { runID.value.uuidString.lowercased() + ".context.json" }
}
