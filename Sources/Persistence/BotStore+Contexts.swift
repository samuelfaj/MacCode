import Foundation
import CoreModel

public extension BotStore {
    @discardableResult
    func grantContext(hostID: String, botID: BotID, context: BotContext, actions: Set<BotContextAction>, expectedRevision: Int64?) throws -> BotContextBinding {
        guard !hostID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BotStoreError.invalidInput("hostID must be nonempty")
        }
        let binding = try db.transaction {
            let raw = try db.prepare("SELECT 1 FROM bot_context_bindings WHERE host_id=? AND bot_id=? AND context_key=?;")
            try raw.bind(1, hostID)
            try raw.bind(2, botID.value.uuidString.lowercased())
            try raw.bind(3, context.storageKey)
            let rowExists = try raw.step()
            raw.reset()
            let old = try contextBinding(hostID: hostID, botID: botID, context: context)
            let revision: Int64
            if rowExists {
                guard let old, let expectedRevision, old.policyRevision == expectedRevision, old.policyRevision < Int64.max else { throw BotStoreError.revisionConflict }
                revision = old.policyRevision + 1
            } else {
                guard expectedRevision == nil || expectedRevision == 0 else { throw BotStoreError.revisionConflict }
                revision = 1
            }
            let bot = try db.prepare("SELECT 1 FROM bots WHERE id = ? AND deleted_at IS NULL LIMIT 1;")
            try bot.bind(1, botID.value.uuidString.lowercased())
            defer { bot.reset() }
            guard try bot.step() else { throw BotStoreError.notFound }
            let encoded = actions.map(\.rawValue).sorted().joined(separator: ",")
            let write = try db.prepare("INSERT INTO bot_context_bindings(host_id, bot_id, context_key, contract_version, state, policy_revision, actions) VALUES(?, ?, ?, ?, 'active', ?, ?) ON CONFLICT(host_id, bot_id, context_key) DO UPDATE SET contract_version=excluded.contract_version, state='active', policy_revision=excluded.policy_revision, actions=excluded.actions;")
            try write.bind(1, hostID)
            try write.bind(2, botID.value.uuidString.lowercased())
            try write.bind(3, context.storageKey)
            try write.bind(4, BotContext.contractVersion)
            try write.bind(5, revision)
            try write.bind(6, encoded)
            _ = try write.step()
            return BotContextBinding(hostID: hostID, botID: botID, context: context, state: .active, policyRevision: revision, actions: actions)
        }
        bumpBotsListRevision()
        return binding
    }

    func revokeContext(hostID: String, botID: BotID, context: BotContext, expectedRevision: Int64) throws -> BotContextBinding {
        let binding = try db.transaction {
            guard let old = try contextBinding(hostID: hostID, botID: botID, context: context), old.policyRevision == expectedRevision, old.policyRevision < Int64.max else { throw BotStoreError.revisionConflict }
            let revision = old.policyRevision + 1
            let update = try db.prepare("UPDATE bot_context_bindings SET state='revoked', policy_revision=? WHERE host_id=? AND bot_id=? AND context_key=?;")
            try update.bind(1, revision)
            try update.bind(2, hostID)
            try update.bind(3, botID.value.uuidString.lowercased())
            try update.bind(4, context.storageKey)
            _ = try update.step()
            return BotContextBinding(hostID: hostID, botID: botID, context: context, state: .revoked, policyRevision: revision, actions: old.actions)
        }
        bumpBotsListRevision()
        return binding
    }

    func getContextBinding(hostID: String, botID: BotID, context: BotContext) throws -> BotContextBinding? {
        try contextBinding(hostID: hostID, botID: botID, context: context)
    }

    func listContextBindings(hostID: String, botID: BotID) throws -> [BotContextBinding] {
        let statement = try db.prepare("SELECT context_key, typeof(contract_version), contract_version, state, typeof(policy_revision), policy_revision, actions FROM bot_context_bindings WHERE host_id=? AND bot_id=? ORDER BY context_key;")
        try statement.bind(1, hostID)
        try statement.bind(2, botID.value.uuidString.lowercased())
        defer { statement.reset() }
        var result: [BotContextBinding] = []
        while try statement.step() {
            guard statement.columnText(1) == "integer", statement.columnInt64(2) == Int64(BotContext.contractVersion), statement.columnText(4) == "integer", let key = statement.columnText(0), let context = decodeContextKey(key), let state = statement.columnText(3).flatMap(BotContextBindingState.init(rawValue:)), let actions = decodeActions(statement.columnText(6)), statement.columnInt64(5) > 0 else { continue }
            result.append(BotContextBinding(hostID: hostID, botID: botID, context: context, state: state, policyRevision: statement.columnInt64(5), actions: actions))
        }
        return result
    }

    func authorizes(hostID: String, botID: BotID, context: BotContext, action: BotContextAction, policyRevision: Int64) throws -> Bool {
        guard let binding = try contextBinding(hostID: hostID, botID: botID, context: context), binding.state == .active, binding.policyRevision == policyRevision, binding.actions.contains(action) else { return false }
        let bot = try db.prepare("SELECT 1 FROM bots WHERE id=? AND deleted_at IS NULL LIMIT 1;")
        try bot.bind(1, botID.value.uuidString.lowercased())
        defer { bot.reset() }
        return try bot.step()
    }

    private func contextBinding(hostID: String, botID: BotID, context: BotContext) throws -> BotContextBinding? {
        let statement = try db.prepare("SELECT typeof(contract_version), contract_version, state, typeof(policy_revision), policy_revision, actions FROM bot_context_bindings WHERE host_id=? AND bot_id=? AND context_key=?;")
        try statement.bind(1, hostID)
        try statement.bind(2, botID.value.uuidString.lowercased())
        try statement.bind(3, context.storageKey)
        defer { statement.reset() }
        guard try statement.step(), statement.columnText(0) == "integer", statement.columnInt64(1) == Int64(BotContext.contractVersion), let state = statement.columnText(2).flatMap(BotContextBindingState.init(rawValue:)), statement.columnText(3) == "integer", statement.columnInt64(4) > 0, let actions = decodeActions(statement.columnText(5)) else { return nil }
        return BotContextBinding(hostID: hostID, botID: botID, context: context, state: state, policyRevision: statement.columnInt64(4), actions: actions)
    }

    private func decodeActions(_ value: String?) -> Set<BotContextAction>? {
        guard let value else { return nil }
        if value.isEmpty { return [] }
        let names = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let actions = names.compactMap(BotContextAction.init(rawValue:))
        guard actions.count == names.count, Set(actions).count == actions.count, names == actions.map(\.rawValue).sorted() else { return nil }
        return Set(actions)
    }

    private func decodeContextKey(_ value: String) -> BotContext? {
        if value == "general:v1" { return .general }
        let prefix = "workspace:v1:"
        guard value.hasPrefix(prefix), let uuid = UUID(uuidString: String(value.dropFirst(prefix.count))) else { return nil }
        return .workspace(WorkspaceID(uuid))
    }
}
