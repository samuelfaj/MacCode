import Foundation
import CoreModel

public extension BotStore {
    func listVirtualMachines() throws -> [BotVirtualMachine] {
        let query = try db.prepare("SELECT id, name, workspace_id, created_at FROM virtual_machines ORDER BY name COLLATE NOCASE, id;")
        defer { query.reset() }
        var machines: [BotVirtualMachine] = []
        while try query.step() {
            guard let raw = query.columnText(0), let id = UUID(uuidString: raw),
                  let name = query.columnText(1) else { throw BotStoreError.invalidRow("virtual_machines") }
            let workspaceID: WorkspaceID?
            if let raw = query.columnText(2) {
                guard let uuid = UUID(uuidString: raw) else { throw BotStoreError.invalidRow("virtual_machines.workspace_id") }
                workspaceID = WorkspaceID(uuid)
            } else { workspaceID = nil }
            machines.append(BotVirtualMachine(id: id, name: name,
                workspaceID: workspaceID,
                createdAt: Date(timeIntervalSince1970: query.columnDouble(3))))
        }
        return machines
    }

    func virtualMachine(id: UUID) throws -> BotVirtualMachine? {
        try listVirtualMachines().first { $0.id == id }
    }

    @discardableResult
    func saveVirtualMachine(id: UUID? = nil, name: String, workspaceID: WorkspaceID? = nil) throws -> BotVirtualMachine {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw BotStoreError.invalidInput("Use a VM name between 1 and 80 characters.")
        }
        return try db.transaction {
            let current = try id.flatMap { try virtualMachine(id: $0) }
            if id != nil, current == nil { throw BotStoreError.invalidInput("This VM is no longer available.") }
            if let current, current.workspaceID != workspaceID {
                throw BotStoreError.invalidInput("A VM's scope cannot change. Create another VM for the new scope.")
            }
            guard try !listVirtualMachines().contains(where: {
                $0.id != id && $0.workspaceID == workspaceID && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else { throw BotStoreError.invalidInput("A VM with this name already exists in this scope.") }
            let machine = BotVirtualMachine(id: id ?? UUID(), name: name, workspaceID: workspaceID,
                createdAt: current?.createdAt ?? Date())
            let statement = try db.prepare("""
                INSERT INTO virtual_machines(id,name,workspace_id,created_at) VALUES(?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET name=excluded.name;
                """)
            defer { statement.reset() }
            try statement.bind(1, machine.id.uuidString.lowercased())
            try statement.bind(2, name)
            try statement.bind(3, workspaceID?.value.uuidString.lowercased())
            try statement.bind(4, machine.createdAt.timeIntervalSince1970)
            _ = try statement.step()
            return machine
        }
    }

    func executionDestination(botID: BotID) throws -> BotExecutionDestination {
        // One queue hop: every send reads this several times on the main thread.
        let (revision, raw): (BotRevision, String?) = try db.performSync { database in
            guard let bot = try loadBot(id: botID, database: database), bot.deletedAt == nil,
                  let revisionID = bot.currentRevisionID,
                  let revision = try loadRevision(id: revisionID, database: database) else {
                throw BotStoreError.notFound
            }
            let query = try database.prepare("SELECT execution_destination FROM bots WHERE id=?;")
            defer { query.reset() }
            try query.bind(1, botID.value.uuidString.lowercased())
            guard try query.step() else { throw BotStoreError.notFound }
            return (revision, query.columnText(0))
        }
        guard let raw else {
            return BotExecutionDefault.target(for: revision) == .vm ? .ownVM : .mac
        }
        guard let destination = BotExecutionDestination(storageValue: raw) else {
            throw BotStoreError.invalidInput("This destination requires a newer version of MacCode.")
        }
        return destination
    }

    func validateExecutionDestination(_ destination: BotExecutionDestination, botID: BotID,
                                      workspaceID: WorkspaceID? = nil,
                                      contextPin: BotConversationContextPin? = nil) throws {
        guard let bot = try get(id: botID), bot.deletedAt == nil else { throw BotStoreError.notFound }
        if let owner = bot.workspaceID, let workspaceID, workspaceID != owner {
            // A conversation's explicit grant is authoritative over the legacy
            // catalog workspace. It never grants access to another workspace's VM.
            guard let pin = contextPin, pin.botID == botID, pin.context == .workspace(workspaceID),
                  try authorizes(hostID: pin.hostID, botID: botID, context: pin.context,
                                 action: .read, policyRevision: pin.policyRevision),
                  try authorizes(hostID: pin.hostID, botID: botID, context: pin.context,
                                 action: .send, policyRevision: pin.policyRevision) else {
                throw BotStoreError.invalidInput("This bot belongs to another workspace.")
            }
        }
        guard let id = destination.virtualMachineID else { return }
        guard let machine = try virtualMachine(id: id) else {
            throw BotStoreError.invalidInput("This VM is no longer available. Choose another destination.")
        }
        guard machine.allows(bot) else {
            throw BotStoreError.invalidInput("Workspace VMs are available only to bots exclusive to that workspace.")
        }
        if let owner = machine.workspaceID {
            if let workspaceID, workspaceID != owner {
                throw BotStoreError.invalidInput("This VM belongs to another workspace.")
            }
        }
    }

    /// Saves the desktop and destination together; every sender reads this same host-owned choice.
    @discardableResult
    func setExecutionDestination(_ destination: BotExecutionDestination, botID: BotID) throws -> BotRevision {
        try validateExecutionDestination(destination, botID: botID)
        guard let bot = try get(id: botID), let revisionID = bot.currentRevisionID,
              let current = try getRevision(id: revisionID) else { throw BotStoreError.notFound }
        return try publish(botID: botID, expectedCurrentRevisionID: revisionID,
            draft: BotRevisionDraft(name: bot.name, title: current.title, description: current.description,
                soul: current.soul, permissionMode: current.permissionMode,
                desktopKind: destination.target == .vm ? .dockerDesktop : .logicalExecutionSpace),
            beforeCommit: { _ in try self.writeExecutionDestination(destination, botID: botID) })
    }

    func writeExecutionDestination(_ destination: BotExecutionDestination, botID: BotID) throws {
        try validateExecutionDestination(destination, botID: botID)
        let statement = try db.prepare("UPDATE bots SET execution_destination=? WHERE id=? AND deleted_at IS NULL;")
        defer { statement.reset() }
        try statement.bind(1, destination.storageValue)
        try statement.bind(2, botID.value.uuidString.lowercased())
        _ = try statement.step()
        guard destination == .mac else { return }
        // The Bot no longer has its own VM: its own-VM conversations follow it
        // to the Mac. Shared VM pins stay; reconcile then retargets them.
        let repin = try db.prepare("""
            UPDATE agent_threads SET execution_destination='mac'
            WHERE execution_destination='own_vm'
              AND lower(id) IN (SELECT lower(linked_agent_thread_id) FROM bot_conversations WHERE bot_id=?);
            """)
        defer { repin.reset() }
        try repin.bind(1, botID.value.uuidString.lowercased())
        _ = try repin.step()
    }

    func threadExecutionDestination(_ threadID: AgentThreadID) throws -> BotExecutionDestination? {
        let query = try db.prepare("SELECT execution_destination FROM agent_threads WHERE id=?;")
        defer { query.reset() }
        try query.bind(1, threadID.value.uuidString)
        guard try query.step(), let raw = query.columnText(0) else { return nil }
        guard let destination = BotExecutionDestination(storageValue: raw) else {
            throw BotStoreError.invalidInput("This conversation's destination requires a newer version of MacCode.")
        }
        return destination
    }

    /// Pins once. Subsequent default changes apply only to new conversations.
    func pinExecutionDestination(threadID: AgentThreadID, botID: BotID,
                                 destination: BotExecutionDestination, replace: Bool = false) throws {
        try validateExecutionDestination(destination, botID: botID)
        let statement = try db.prepare("""
            UPDATE agent_threads SET execution_destination=? WHERE id=?
            \(replace ? "" : "AND execution_destination IS NULL");
            """)
        defer { statement.reset() }
        try statement.bind(1, destination.storageValue)
        try statement.bind(2, threadID.value.uuidString)
        _ = try statement.step()
    }

    /// Resolves a storage namespace, never an actor identity.
    func guestResourceID(botID: BotID, threadID: AgentThreadID? = nil) throws -> BotID {
        let destination = try threadID.flatMap { try threadExecutionDestination($0) } ?? executionDestination(botID: botID)
        try validateExecutionDestination(destination, botID: botID)
        if let id = destination.virtualMachineID { return BotID(id) }
        return botID
    }

    func contextRuntimeIdentity(pin: BotConversationContextPin, threadID: AgentThreadID) throws -> BotContextRuntimeIdentity {
        let destination = try threadExecutionDestination(threadID) ?? executionDestination(botID: pin.botID)
        let workspaceID: WorkspaceID? = if case .workspace(let id) = pin.context { id } else { nil }
        try validateExecutionDestination(destination, botID: pin.botID, workspaceID: workspaceID, contextPin: pin)
        return try BotContextRuntimeIdentity(hostID: pin.hostID, botID: pin.botID, context: pin.context,
            policyRevision: pin.policyRevision, virtualMachineID: destination.virtualMachineID)
    }

}
