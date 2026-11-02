import CryptoKit
import Foundation
import Persistence
import CoreModel
import AgentRuntime

public enum HostMutationContract {
    public static let transportParamKeys: Set<String> = [
        "client_request_id", "connection_id", "expected_host_id", "expected_boot_epoch",
        BotPeerDelegation.capabilityRPCParameterKey,
    ]

    public static let methods: Set<String> = Set("""
    workspace.create
    workspace.rename
    workspace.close
    workspace.select
    workspace.reorder
    workspace.set_color
    workspace.set_description
    workspace.set_pinned
    workspace.move_to_window
    window.create
    window.close
    window.focus
    pane.resize
    pane.swap
    surface.create
    surface.close
    surface.focus
    surface.move
    surface.rename
    surface.reorder
    surface.set_color
    surface.split
    surface.clear_history
    surface.send_key
    surface.send_text
    agent.open
    agent.thread.create
    agent.thread.delete
    agent.thread.delete_many
    agent.thread.rename
    agent.thread.loop.stop
    agent.thread.set_pinned
    agent.thread.set_color
    agent.thread.reorder
    agent.thread.configure
    agent.thread.execution.configure
    agent.thread.mark_read
    agent.activity.viewed.set
    agent.activity.acknowledge
    scheduled_task.save
    scheduled_task.delete
    scheduled_task.enable
    scheduled_task.run
    agent.thread.prepare_pr
    agent.thread.rollback
    agent.thread.select
    agent.message.send
    agent.message.queue.cancel
    agent.message.queue.force_now
    agent.message.queue.reorder
    agent.message.queue.update
    agent.run.continue
    agent.run.stop
    agent.request.respond
    agent.user_input.respond
    agent.manual_action.resolve
    agent.thread.actor.set
    agent.mac_execution.resolve
    agent.plan.implement
    agent.plan.save
    agent.plan.notes.save
    agent.checkpoint.revert
    agent.attachment.upload
    agent.attachment.import
    agent.provider.update
    distill.accounts.login
    distill.accounts.logout
    distill.accounts.cancel
    distill.accounts.add
    distill.accounts.rename
    distill.accounts.remove
    distill.accounts.usage
    distill.accounts.routing.set
    fs.mkdir
    fs.workspace.create_file
    fs.workspace.delete
    fs.workspace.rename
    files.edit.apply_patch
    files.edit.open
    files.edit.save
    files.edit.discard
    files.edit.close
    files.state.update
    files.tab.open
    files.tab.split
    git.checkout
    git.commit
    git.create_branch
    git.deliver
    git.push
    git.fetch
    git.pull
    browser.navigate
    browser.back
    browser.forward
    browser.reload
    browser.stop
    browser.click
    browser.fill
    browser.type
    browser.focus
    browser.hover
    browser.check
    browser.uncheck
    browser.select
    browser.eval
    browser.mirror_url.get
    browser.screenshot
    host.browser.screenshot
    host.chat.image
    ssh.connect
    ssh.disconnect
    ssh.host.upsert
    ssh.host.delete
    ssh.transfer.upload
    ssh.transfer.download
    ssh.files.remote.mkdir
    ssh.files.remote.rename
    ssh.files.remote.delete
    notification.create
    notification.dismiss
    notification.mark_read
    settings.set
    project.open_in_editor
    project.run_script
    private.push_token.update
    bot.create
    bot.discard_new
    bot.save
    bot.delete
    bot.context.grant
    bot.context.revoke
    bot.set_pinned
    bot.set_hidden
    bot.reorder
    bot.duplicate
    bot.settings.set
    bot.send
    bot.queue.remove
    bot.queue.update
    bot.queue.reorder
    bot.queue.force_now
    bot.stop
    bot.force_stop
    bot.conversation.create
    bot.conversation.enqueue
    bot.conversation.select
    bot.conversation.clear_all
    bot.routine.create
    bot.routine.update
    bot.routine.enable
    bot.routine.run
    bot.routine.delete
    bot.attachment.stage
    bot.attachment.import
    bot.attachment.remove
    bot.files.mutate
    bot.files.open_tab
    bot.files.split
    bot.files.location.set
    bot.browser.action
    bot.link.open
    bot.guest.input
    bot.guest.start
    bot.guest.stop
    bot.guest.rebuild
    bot.guest.revoke
    bot.guest.control
    bot.docker.clear
    bot.notify.set
    bot.conversation.fork
    bot.verbosity.set
    bot.caveman.set
    bot.factory_reset
    bot.notice.act
    bot.notice.reply
    bot.notice.read
    bot.notice.clear
    bot.desktop.set
    bot.vm.save
    bot.execution.set
    bot.avatar.set
    bot.handle.set
    bot.soul.set
    bot.routing.set
    bot.attention.ack
    bot.self_config
    bot.scheduler.tick
    bot.team.create
    bot.team.update
    bot.team.set_members
    bot.team.delete
    bot.team.reorder
    bot.group.create
    bot.group.update
    bot.group.set_participants
    bot.group.send
    bot.group.stop
    bot.group.retry_turn
    bot.group.select
    bot.group.delete
    """.split(separator: "\n").map(String.init))

    struct PreflightProbe {
        let label: String
        let params: [String: JSONValue]
    }

    private enum SyntaxRule {
        case uuid(String)
        case optionalUUID(String)
        /// Absent, null or a string; any other type is invalid params.
        case optionalString(String)
        case anyUUID([String])
        case string(String, nonempty: Bool = false)
        case anyString([String], nonempty: Bool = false)
        case int(String)
        case firstPresentInt([String])
        case bool(String)
        case object(String)
        case nestedInt(object: String, key: String)
        case stringEnum(String, Set<String>)
        case surfaceType(String)
        case uuidArrayWithAtLeastOne(String)
        /// An array of UUID strings; may be empty.
        case uuidArray(String)
        case stringArrayWithAtLeastOne(String)
        case surfaceSplitTarget
        case requiredSSHProfile
        case optionalSSHProfile
        case pushTokenContract
        /// `actor` `{"kind":"none"}` or `{"kind":"bot","bot_id":<uuid>}`, and an
        /// optional `execution_target` `vm` / `mac` (absent or null for the default).
        case threadActor
        case activityItemIDs(allowSingle: Bool)
        case optionalBool(String)
    }

    /// Private managed-provider mutations reuse the same syntactic and durable
    /// receipt machinery, but they are not part of the public HTTP Phase 4
    /// catalog. Only the authenticated Unix entry point may route them here.
    static let managedProviderMutationMethods =
        RemoteCodeHostCatalog.rpcMutationMethods.union([
            "bot.peer.ask", "bot.peer.self_config", "bot.peer.cancel",
        ])

    public static func preflight(method: String, params: [String: JSONValue]) throws {
        guard methods.contains(method) || managedProviderMutationMethods.contains(method) else {
            throw JSONRPCError.invalidParams
        }
        for rule in syntaxRules(for: method) {
            try validate(rule, params: params)
        }
    }

    static func invalidPreflightProbes(method: String) -> [PreflightProbe] {
        let rules = syntaxRules(for: method)
        var valid: [String: JSONValue] = [:]
        for rule in rules { applyValid(rule, to: &valid) }
        return rules.flatMap { invalidVariants(for: $0, valid: valid) }
    }

    static func validPreflightProbe(method: String) -> [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        for rule in syntaxRules(for: method) { applyValid(rule, to: &params) }
        return params
    }

    /// The same entrance requirements used by admission, exposed to Titio on
    /// demand. These are not a complete schema for optional domain fields.
    static func parameterRequirements(for method: String) -> [String] {
        syntaxRules(for: method).map { rule in
            switch rule {
            case .uuid(let key): return "\(key): required UUID"
            case .optionalUUID(let key): return "\(key): optional UUID"
            case .optionalString(let key): return "\(key): optional string or null"
            case .anyUUID(let keys): return "one of \(keys.joined(separator: ", ")): required UUID"
            case .string(let key, let nonempty): return "\(key): required \(nonempty ? "non-empty " : "")string"
            case .anyString(let keys, let nonempty): return "one of \(keys.joined(separator: ", ")): required \(nonempty ? "non-empty " : "")string"
            case .int(let key): return "\(key): required integer"
            case .firstPresentInt(let keys): return "first present of \(keys.joined(separator: ", ")): required integer"
            case .bool(let key): return "\(key): required boolean"
            case .optionalBool(let key): return "\(key): optional boolean"
            case .object(let key): return "\(key): required object"
            case .nestedInt(let object, let key): return "\(object).\(key): required integer"
            case .stringEnum(let key, let values): return "\(key): one of \(values.sorted().joined(separator: ", "))"
            case .surfaceType(let key): return "\(key): terminal, ssh, browser, agentApp, files, markdown, filePreview or rightSidebarTool"
            case .uuidArrayWithAtLeastOne(let key): return "\(key): array containing at least one UUID"
            case .uuidArray(let key): return "\(key): array of UUIDs"
            case .stringArrayWithAtLeastOne(let key): return "\(key): array of at least one non-empty string"
            case .surfaceSplitTarget: return "id (existing surface UUID) or type (new surface type) is required"
            case .requiredSSHProfile: return "profile or top-level destination/host is required"
            case .optionalSSHProfile: return "profile is optional; when supplied it needs destination or host"
            case .pushTokenContract: return "push_token and push_token_type are required; typed registrations require the push-token contract"
            case .threadActor: return "actor: {kind:none} or {kind:bot,bot_id:UUID}; execution_target: optional mac or vm"
            case .activityItemIDs(let allowSingle): return "item_ids: up to 200 distinct strings\(allowSingle ? "; alternatively item_id: string" : "")"
            }
        }
    }

    private static func validate(_ rule: SyntaxRule, params: [String: JSONValue]) throws {
        switch rule {
        case .uuid(let key):
            guard params[key]?.stringValue.flatMap(UUID.init) != nil else { throw JSONRPCError.invalidParams }
        case .optionalUUID(let key):
            guard params[key] == nil || params[key]?.stringValue.flatMap(UUID.init) != nil else {
                throw JSONRPCError.invalidParams
            }
        case .optionalString(let key):
            guard params[key] == nil || params[key] == .null || params[key]?.stringValue != nil else {
                throw JSONRPCError.invalidParams
            }
        case .anyUUID(let keys):
            guard keys.contains(where: { params[$0]?.stringValue.flatMap(UUID.init) != nil }) else {
                throw JSONRPCError.invalidParams
            }
        case .string(let key, let nonempty):
            guard let value = params[key]?.stringValue, !nonempty || !value.isEmpty else {
                throw JSONRPCError.invalidParams
            }
        case .anyString(let keys, let nonempty):
            guard let value = keys.lazy.compactMap({ params[$0]?.stringValue }).first,
                  !nonempty || !value.isEmpty else { throw JSONRPCError.invalidParams }
        case .int(let key):
            guard params[key]?.intValue != nil else { throw JSONRPCError.invalidParams }
        case .firstPresentInt(let keys):
            guard let key = keys.first(where: { params[$0] != nil }),
                  params[key]?.intValue != nil else { throw JSONRPCError.invalidParams }
        case .bool(let key):
            guard params[key]?.boolValue != nil else { throw JSONRPCError.invalidParams }
        case .optionalBool(let key):
            guard params[key] == nil || params[key]?.boolValue != nil else { throw JSONRPCError.invalidParams }
        case .activityItemIDs(let allowSingle):
            if let itemIDs = params["item_ids"]?.arrayValue {
                guard itemIDs.count <= 200,
                      itemIDs.allSatisfy({ $0.stringValue != nil }),
                      Set(itemIDs.compactMap(\.stringValue)).count == itemIDs.count else {
                    throw JSONRPCError.invalidParams
                }
            } else if allowSingle {
                guard params["item_ids"] == nil,
                      params["item_id"]?.stringValue != nil else { throw JSONRPCError.invalidParams }
            } else {
                throw JSONRPCError.invalidParams
            }
            if params["item_id"] != nil, params["item_id"]?.stringValue == nil {
                throw JSONRPCError.invalidParams
            }
        case .object(let key):
            guard params[key]?.objectValue != nil else { throw JSONRPCError.invalidParams }
        case .nestedInt(let object, let key):
            guard params[object]?.objectValue?[key]?.intValue != nil else { throw JSONRPCError.invalidParams }
        case .stringEnum(let key, let values):
            guard params[key]?.stringValue.map(values.contains) == true else { throw JSONRPCError.invalidParams }
        case .surfaceType(let key):
            guard params[key]?.stringValue.map(isSurfaceType) == true else { throw JSONRPCError.invalidParams }
        case .uuidArray(let key):
            guard let values = params[key]?.arrayValue,
                  values.allSatisfy({ $0.stringValue.flatMap(UUID.init) != nil }) else {
                throw JSONRPCError.invalidParams
            }
        case .stringArrayWithAtLeastOne(let key):
            guard let values = params[key]?.arrayValue, !values.isEmpty,
                  values.allSatisfy({ !($0.stringValue ?? "").isEmpty }) else {
                throw JSONRPCError.invalidParams
            }
        case .uuidArrayWithAtLeastOne(let key):
            guard let values = params[key]?.arrayValue,
                  values.contains(where: { $0.stringValue.flatMap(UUID.init) != nil }) else {
                throw JSONRPCError.invalidParams
            }
        case .surfaceSplitTarget:
            let id = params["id"]?.stringValue.flatMap(UUID.init)
            let type = params["type"]?.stringValue.map(isSurfaceType) == true
            guard id != nil || type else { throw JSONRPCError.invalidParams }
        case .requiredSSHProfile:
            try validateSSHProfile(params)
        case .optionalSSHProfile:
            if params["destination"]?.stringValue != nil || params["host"]?.stringValue != nil || params["profile"]?.objectValue != nil {
                try validateSSHProfile(params)
            }
        case .pushTokenContract:
            try validatePushToken(params)
        case .threadActor:
            guard ThreadActorWire.parseActor(params["actor"]) != nil else { throw JSONRPCError.invalidParams }
            let target = params["execution_target"]
            guard target == nil || target == .null
                || target?.stringValue.flatMap(ExecutionTarget.init(rawValue:)) != nil else {
                throw JSONRPCError.invalidParams
            }
        }
    }

    private static func validateSSHProfile(_ params: [String: JSONValue]) throws {
        let source = params["profile"]?.objectValue ?? params
        guard source["destination"]?.stringValue != nil || source["host"]?.stringValue != nil else {
            throw JSONRPCError.invalidParams
        }
    }

    private static func validatePushToken(_ params: [String: JSONValue]) throws {
        guard let pushToken = params["push_token"]?.stringValue, !pushToken.isEmpty,
              ["apns", "fcm"].contains(params["push_token_type"]?.stringValue ?? "") else {
            throw JSONRPCError.invalidParams
        }
        let tokenPurpose = params["token_purpose"]?.stringValue
        let environment = params["environment"]?.stringValue
        let serverID = params["server_id"]?.stringValue
        let bootEpoch = params["boot_epoch"]?.intValue
        let activityGeneration = params["activity_generation"]?.intValue
        let activityID = params["activity_id"]?.stringValue
        let activitySessionID = params["activity_session_id"]?.stringValue
        let registrationRevision = params["registration_revision"]?.intValue
        let contractVersion = params["contract_version"]?.intValue
        let capabilityValues = params["capabilities"]?.arrayValue
        let capabilities = capabilityValues?.compactMap(\.stringValue)
        let typed = tokenPurpose != nil || environment != nil || serverID != nil ||
            params["boot_epoch"] != nil || params["activity_generation"] != nil ||
            params["activity_id"] != nil || params["activity_session_id"] != nil ||
            params["registration_revision"] != nil || contractVersion != nil || params["capabilities"] != nil
        guard typed else { return }
        guard params["activity_generation"] == nil || activityGeneration != nil,
              params["boot_epoch"] == nil || bootEpoch != nil,
              params["activity_session_id"] == nil || activitySessionID != nil,
              params["registration_revision"] == nil || registrationRevision != nil,
              params["activity_id"] == nil || activityID != nil,
              params["contract_version"] == nil || contractVersion != nil,
              params["capabilities"] == nil || (capabilityValues != nil && capabilityValues?.count == capabilities?.count),
              ["alert", "push_to_start", "activity_update"].contains(tokenPurpose ?? ""),
              ["sandbox", "production"].contains(environment ?? ""),
              let deviceID = params["device_id"]?.stringValue, !deviceID.isEmpty,
              let serverID, !serverID.isEmpty,
              bootEpoch.map({ $0 >= 0 }) ?? true,
              activityGeneration.map({ $0 >= 0 }) ?? true,
              registrationRevision.map({ $0 >= 0 }) ?? true,
              contractVersion.map({ $0 >= 1 }) ?? true else { throw JSONRPCError.invalidParams }
        if tokenPurpose != "alert" {
            guard let token = params["live_activity_token"]?.stringValue, !token.isEmpty else {
                throw JSONRPCError.invalidParams
            }
        }
        if capabilities?.contains("live_activity_v2") == true, (contractVersion ?? 1) < 2 {
            throw JSONRPCError.invalidParams
        }
    }

    private static func syntaxRules(for method: String) -> [SyntaxRule] {
        if method.hasPrefix("bot.") {
            switch method {
            case "bot.create", "bot.scheduler.tick", "bot.self_config":
                return []
            case "bot.settings.set":
                return [.string("key")]
            case "bot.vm.save":
                return [.string("name", nonempty: true)]
            case "bot.execution.set":
                return [.uuid("bot_id"), .string("execution_destination", nonempty: true)]
            case "bot.reorder":
                return [.uuidArray("ordered_bot_ids")]
            case "bot.queue.remove", "bot.queue.force_now":
                return [.uuid("bot_id"), .uuid("id")]
            case "bot.queue.update":
                return [.uuid("bot_id"), .uuid("id"), .string("text", nonempty: true)]
            case "bot.queue.reorder":
                return [.uuid("bot_id"), .uuid("id"), .int("position")]
            case "bot.peer.ask":
                return [
                    .uuid("thread_id"), .uuid("run_id"), .string("handle"), .string("prompt"),
                    .stringEnum("reply_mode", ["consult", "reply_only"]),
                    .optionalUUID(BotPeerDelegation.consultationIDParameterKey), .optionalBool("wait"),
                ]
            case "bot.peer.cancel":
                return [.uuid("thread_id"), .uuid("run_id"), .uuid("activity_id"), .optionalBool("wait")]
            case "bot.peer.self_config":
                return [
                    .uuid("thread_id"), .uuid("run_id"), .string("tool_name"), .object("arguments"),
                ]
            case "bot.attention.ack":
                return [
                    .uuid("bot_id"),
                    .string("profile_id", nonempty: true),
                    .string("host_id", nonempty: true),
                    .anyString(["attention_item_id", "notification_id", "item_id"], nonempty: true),
                ]
            case "bot.guest.start":
                return [
                    .uuid("bot_id"),
                    .string("task_id", nonempty: true), .string("recipe_id", nonempty: true),
                ]
            case "bot.guest.input":
                return [
                    .uuid("bot_id"),
                    .string("task_id", nonempty: true), .object("runtime"),
                    .string("before_frame_id", nonempty: true), .object("input"),
                ]
            case "bot.guest.stop", "bot.guest.rebuild", "bot.guest.revoke":
                return [
                    .uuid("bot_id"),
                    .string("task_id", nonempty: true), .object("runtime"),
                ]
            case "bot.guest.control":
                return [.uuid("bot_id"), .stringEnum("action", ["take", "release"])]
            case "bot.notice.reply":
                return [.uuid("bot_id"), .uuid("message_id"), .string("text", nonempty: true)]
            case "bot.notice.act":
                return [.uuid("bot_id"), .uuid("message_id"), .int("option_index")]
            case "bot.notice.read":
                return [.uuid("bot_id"), .uuid("conversation_id")]
            case "bot.notice.clear":
                return [.uuid("bot_id"), .uuid("message_id")]
            case "bot.team.create":
                return [.string("name", nonempty: true)]
            case "bot.team.update":
                return [.uuid("team_id"), .int("expected_revision")]
            case "bot.team.set_members":
                return [.uuid("team_id"), .int("expected_revision"), .uuidArray("bot_ids")]
            case "bot.team.delete":
                return [.uuid("team_id")]
            case "bot.team.reorder":
                return [.uuidArray("team_ids")]
            case "bot.group.create":
                return [.string("title", nonempty: true), .uuidArrayWithAtLeastOne("participant_bot_ids")]
            case "bot.group.update":
                return [.uuid("group_id"), .int("expected_revision")]
            case "bot.group.set_participants":
                return [.uuid("group_id"), .int("expected_revision"), .uuidArrayWithAtLeastOne("bot_ids")]
            case "bot.group.send":
                return [.uuid("group_id"), .string("text", nonempty: true), .string("submit_key", nonempty: true)]
            case "bot.group.stop", "bot.group.select", "bot.group.delete":
                return [.uuid("group_id")]
            case "bot.group.retry_turn":
                return [.uuid("group_id"), .uuid("turn_id")]
            default:
                return [.uuid("bot_id")]
            }
        }
        switch method {
        case "workspace.create", "host.workspace.create", "window.create", "agent.thread.create", "host.agent.thread.create", "agent.provider.update", "notification.create": return []
        case "workspace.rename": return [.uuid("id"), .string("name")]
        case "workspace.close", "workspace.select", "workspace.reorder", "window.close", "window.focus": return [.uuid("id")]
        case "workspace.set_color": return [.uuid("id"), .string("color")]
        case "workspace.set_description": return [.uuid("id"), .anyString(["description", "text"])]
        case "workspace.set_pinned": return [.uuid("id"), .bool("pinned")]
        case "workspace.move_to_window": return [.uuid("workspace_id"), .uuid("window_id")]
        case "pane.resize": return [.uuid("workspace_id"), .uuid("split_id")]
        case "pane.swap": return [.uuid("workspace_id"), .uuid("a"), .uuid("b")]
        case "surface.create": return [.uuid("workspace_id"), .surfaceType("type")]
        case "surface.close", "surface.focus": return [.uuid("workspace_id"), .uuid("id")]
        case "surface.move", "surface.reorder": return [.uuid("workspace_id"), .uuid("id"), .uuid("target_pane_id")]
        case "surface.rename": return [.uuid("workspace_id"), .uuid("id"), .string("title")]
        case "surface.set_color": return [.uuid("workspace_id"), .uuid("id"), .string("color")]
        case "surface.split": return [.uuid("workspace_id"), .uuid("pane_id"), .stringEnum("direction", directions), .surfaceSplitTarget]
        case "surface.clear_history": return [.uuid("id")]
        case "surface.send_key": return [.uuid("id"), .string("key")]
        case "surface.send_text": return [.uuid("id"), .string("text")]
        case "agent.open": return [.uuid("workspace_id")]
        case "agent.thread.delete", "agent.thread.reorder", "agent.thread.configure", "agent.thread.mark_read", "agent.thread.select", "agent.run.continue", "agent.run.stop": return [.uuid("thread_id")]
        case "agent.thread.delete_many": return [.uuidArrayWithAtLeastOne("thread_ids")]
        case "agent.thread.rename": return [.uuid("thread_id"), .string("title")]
        case "agent.thread.loop.stop": return [.uuid("thread_id"), .string("task_id")]
        case "agent.thread.set_pinned": return [.uuid("thread_id"), .bool("pinned")]
        case "agent.thread.set_color": return [.uuid("thread_id"), .string("color")]
        case "agent.thread.execution.configure": return [.uuid("thread_id"), .stringEnum("execution_mode", ["local", "worktree"])]
        case "agent.activity.viewed.set": return [.activityItemIDs(allowSingle: false), .bool("viewed")]
        case "agent.activity.acknowledge": return [.activityItemIDs(allowSingle: true), .optionalBool("acknowledged")]
        case "scheduled_task.save": return [.anyUUID(["workspace_id", "bot_id"]), .optionalUUID("task_id")]
        case "scheduled_task.delete", "scheduled_task.run": return [.uuid("task_id")]
        case "scheduled_task.enable": return [.uuid("task_id"), .bool("enabled")]
        case "agent.thread.prepare_pr": return [.uuid("workspace_id"), .string("url")]
        case "agent.thread.rollback": return [.uuid("thread_id"), .string("turn_id")]
        case "agent.message.send": return [.uuid("thread_id"), .string("text")]
        case "agent.message.queue.cancel", "agent.message.queue.force_now": return [.anyUUID(["queued_message_id", "id"])]
        case "agent.message.queue.update": return [.anyUUID(["queued_message_id", "id"]), .string("text")]
        case "agent.message.queue.reorder": return [.uuid("thread_id"), .anyUUID(["queued_message_id", "id"]), .int("position")]
        case "agent.request.respond": return [.uuid("thread_id"), .string("request_id"), .stringEnum("decision", ["approve", "approve_for_session", "approveForSession", "decline", "cancel"])]
        case "agent.user_input.respond": return [.uuid("thread_id"), .string("request_id"), .string("text")]
        case "agent.thread.actor.set": return [.uuid("thread_id"), .threadActor]
        case "agent.mac_execution.resolve": return [.uuid("thread_id"), .bool("approve")]
        case "agent.manual_action.resolve": return [.uuid("thread_id"), .uuid("manual_action_id"), .stringEnum("action", ["take", "continue", "decline"]), .optionalString("note")]
        case "agent.plan.implement", "agent.plan.save": return [.uuid("thread_id"), .string("plan_id")]
        case "agent.plan.notes.save": return [.uuid("thread_id"), .string("notes")]
        case "agent.checkpoint.revert": return [.uuid("thread_id"), .firstPresentInt(["turn_count", "checkpoint_turn_count"])]
        case "agent.attachment.upload": return [.uuid("workspace_id"), .string("filename"), .anyString(["data_base64", "dataBase64"])]
        case "agent.attachment.import": return [.uuid("workspace_id"), .string("relative_path", nonempty: true)]
        case "host.bot.create": return [.string("name", nonempty: true)]
        case "host.bot.open": return [.uuid("bot_id")]
        case "host.bot.send": return [.uuid("bot_id"), .string("text", nonempty: true)]
        case "host.bot.thread.create": return [.uuid("bot_id")]
        case "host.bot.skill.create": return [.uuid("bot_id"), .string("skill_id", nonempty: true)]
        case "host.bot.delegate": return [.string("bot", nonempty: true), .string("text", nonempty: true)]
        case "host.scheduled_task.run_next": return [.string("workspace", nonempty: true)]
        case "host.browser.screenshot": return [.uuid("thread_id"), .optionalUUID("surface_id"), .optionalString("reason")]
        case "host.chat.image": return [.uuid("thread_id"), .stringArrayWithAtLeastOne("paths"), .optionalString("caption")]
        case "fs.mkdir": return [.string("path", nonempty: true)]
        case "fs.workspace.create_file": return [.uuid("workspace_id"), .string("path")]
        case "fs.workspace.delete": return [.uuid("workspace_id")]
        case "fs.workspace.rename": return [.uuid("workspace_id"), .string("path"), .string("new_name")]
        case "files.edit.apply_patch": return [.string("session_id"), .int("base_draft_revision"), .object("range_utf16"), .nestedInt(object: "range_utf16", key: "location"), .nestedInt(object: "range_utf16", key: "length"), .string("replacement")]
        case "files.edit.open": return [.uuid("surface_id"), .string("path")]
        case "files.edit.save", "files.edit.discard", "files.edit.close": return [.string("session_id")]
        case "files.state.update": return [.uuid("surface_id"), .object("patch")]
        case "files.tab.open": return [.uuid("workspace_id"), .string("path")]
        case "files.tab.split": return [.uuid("workspace_id"), .stringEnum("direction", directions), .string("path")]
        case "git.checkout": return [.uuid("workspace_id"), .string("branch")]
        case "git.commit": return [.uuid("workspace_id"), .string("message")]
        case "git.create_branch": return [.uuid("workspace_id"), .string("name")]
        case "git.deliver", "git.push", "git.fetch", "git.pull", "project.open_in_editor": return [.uuid("workspace_id")]
        case "browser.navigate": return [.uuid("id"), .string("url")]
        case "browser.back", "browser.forward", "browser.reload", "browser.stop", "browser.mirror_url.get", "browser.screenshot": return [.uuid("id")]
        case "browser.click", "browser.fill", "browser.type", "browser.focus", "browser.hover", "browser.check", "browser.uncheck", "browser.select": return [.uuid("id"), .string("ref")]
        case "browser.eval": return [.uuid("id"), .string("script")]
        case "ssh.connect": return [.uuid("workspace_id"), .optionalSSHProfile]
        case "ssh.disconnect": return [.anyUUID(["surface_id", "id"])]
        case "ssh.host.upsert": return [.anyUUID(["workspace_id", "workspaceId"]), .requiredSSHProfile]
        case "ssh.host.delete": return [.anyUUID(["workspace_id", "workspaceId"]), .uuid("id")]
        case "ssh.transfer.upload", "ssh.transfer.download": return [.anyUUID(["surface_id", "id"]), .string("local_path"), .string("remote_path")]
        case "ssh.files.remote.mkdir", "ssh.files.remote.delete": return [.anyUUID(["surface_id", "id"]), .string("path", nonempty: true)]
        case "ssh.files.remote.rename": return [.anyUUID(["surface_id", "id"]), .string("from_path", nonempty: true), .string("to_path", nonempty: true)]
        case "notification.dismiss", "notification.mark_read": return [.string("id")]
        case "settings.set": return [.string("key"), .string("value")]
        case "project.run_script": return [.uuid("workspace_id"), .string("name")]
        case "private.push_token.update": return [.pushTokenContract]
        case "distill.accounts.login", "distill.accounts.logout": return [.anyString(["account_id", "provider"], nonempty: true)]
        case "distill.accounts.add": return [.stringEnum("provider", distillAccountProviders), .string("label", nonempty: true)]
        case "distill.accounts.rename": return [.string("account_id", nonempty: true), .string("label", nonempty: true)]
        case "distill.accounts.remove", "distill.accounts.usage": return [.string("account_id", nonempty: true)]
        case "distill.accounts.routing.set": return [.object("routing")]
        default: return []
        }
    }

    private static let directions: Set<String> = ["right", "down", "left", "up"]
    private static let distillAccountProviders = Set(DistillAccountProvider.allCases.map(\.rawValue))

    private static func isSurfaceType(_ value: String) -> Bool {
        let lower = value.lowercased()
        let normalized: String
        switch lower {
        case "agent", "agent_app", "agentapp": normalized = "agentApp"
        case "rightsidebartool", "right_sidebar_tool", "diff", "git": normalized = "rightSidebarTool"
        case "filepreview", "file_preview": normalized = "filePreview"
        case "files", "file_browser", "filebrowser": normalized = "files"
        case "terminal", "ssh", "browser", "markdown": normalized = lower
        default: normalized = value
        }
        return ["terminal", "ssh", "browser", "agentApp", "files", "markdown", "filePreview", "rightSidebarTool"].contains(normalized)
    }

    private static let probeUUID = "00000000-0000-0000-0000-000000000001"

    private static func applyValid(_ rule: SyntaxRule, to params: inout [String: JSONValue]) {
        switch rule {
        case .uuid(let key): params[key] = .string(probeUUID)
        case .optionalUUID: break
        case .optionalString: break
        case .anyUUID(let keys): params[keys[0]] = .string(probeUUID)
        case .string(let key, _): params[key] = .string("value")
        case .anyString(let keys, _): params[keys[0]] = .string("value")
        case .int(let key): params[key] = .number(1)
        case .firstPresentInt(let keys): params[keys[0]] = .number(1)
        case .bool(let key): params[key] = .bool(true)
        case .optionalBool: break
        case .activityItemIDs: params["item_ids"] = .array([])
        case .object(let key):
            if params[key]?.objectValue == nil { params[key] = .object([:]) }
        case .nestedInt(let object, let key):
            var value = params[object]?.objectValue ?? [:]
            value[key] = .number(1)
            params[object] = .object(value)
        case .stringEnum(let key, let values): params[key] = .string(values.sorted()[0])
        case .surfaceType(let key): params[key] = .string("terminal")
        case .uuidArrayWithAtLeastOne(let key): params[key] = .array([.string(probeUUID)])
        case .uuidArray(let key): params[key] = .array([.string(probeUUID)])
        case .stringArrayWithAtLeastOne(let key): params[key] = .array([.string("/tmp/probe.png")])
        case .surfaceSplitTarget: params["type"] = .string("terminal")
        case .requiredSSHProfile: params["destination"] = .string("host.example")
        case .optionalSSHProfile: break
        case .pushTokenContract:
            params["push_token"] = .string("token")
            params["push_token_type"] = .string("apns")
        case .threadActor:
            params["actor"] = .object(["kind": .string("bot"), "bot_id": .string(probeUUID)])
        }
    }

    private static func invalidVariants(
        for rule: SyntaxRule,
        valid: [String: JSONValue]
    ) -> [PreflightProbe] {
        var probes: [PreflightProbe] = []
        func add(_ label: String, _ mutate: (inout [String: JSONValue]) -> Void) {
            var params = valid
            mutate(&params)
            probes.append(PreflightProbe(label: label, params: params))
        }
        switch rule {
        case .uuid(let key):
            add("\(key).missing") { $0.removeValue(forKey: key) }
            add("\(key).type") { $0[key] = .bool(true) }
            add("\(key).uuid") { $0[key] = .string("not-a-uuid") }
        case .optionalUUID(let key):
            add("\(key).type") { $0[key] = .bool(true) }
            add("\(key).uuid") { $0[key] = .string("not-a-uuid") }
        case .optionalString(let key):
            add("\(key).type") { $0[key] = .number(1) }
        case .anyUUID(let keys):
            add("\(keys.joined(separator: "/")).missing") { params in keys.forEach { params.removeValue(forKey: $0) } }
            add("\(keys.joined(separator: "/")).type") { params in keys.forEach { params[$0] = .bool(true) } }
            add("\(keys.joined(separator: "/")).uuid") { params in keys.forEach { params[$0] = .string("not-a-uuid") } }
        case .string(let key, let nonempty):
            add("\(key).missing") { $0.removeValue(forKey: key) }
            add("\(key).type") { $0[key] = .bool(true) }
            if nonempty { add("\(key).empty") { $0[key] = .string("") } }
        case .anyString(let keys, let nonempty):
            add("\(keys.joined(separator: "/")).missing") { params in keys.forEach { params.removeValue(forKey: $0) } }
            add("\(keys.joined(separator: "/")).type") { params in keys.forEach { params[$0] = .bool(true) } }
            if nonempty { add("\(keys.joined(separator: "/")).empty") { params in keys.forEach { params[$0] = .string("") } } }
        case .int(let key):
            add("\(key).missing") { $0.removeValue(forKey: key) }
            add("\(key).type") { $0[key] = .bool(true) }
        case .firstPresentInt(let keys):
            add("\(keys.joined(separator: "/")).missing") { params in keys.forEach { params.removeValue(forKey: $0) } }
            add("\(keys.joined(separator: "/")).type") { params in
                params[keys[0]] = .bool(true)
                if keys.count > 1 { params[keys[1]] = .number(1) }
            }
        case .bool(let key):
            add("\(key).missing") { $0.removeValue(forKey: key) }
            add("\(key).type") { $0[key] = .string("true") }
        case .optionalBool(let key):
            add("\(key).type") { $0[key] = .string("true") }
        case .activityItemIDs(let allowSingle):
            add("item_ids.missing") { $0.removeValue(forKey: "item_ids"); $0.removeValue(forKey: "item_id") }
            add("item_ids.type") { $0["item_ids"] = .string("item") }
            add("item_ids.nonstring") { $0["item_ids"] = .array([.number(1)]) }
            add("item_ids.duplicate") { $0["item_ids"] = .array([.string("item"), .string("item")]) }
            add("item_ids.too_many") { $0["item_ids"] = .array((0..<201).map { .string("item-\($0)") }) }
            if allowSingle { add("item_id.type") { $0.removeValue(forKey: "item_ids"); $0["item_id"] = .number(1) } }
        case .object(let key):
            add("\(key).missing") { $0.removeValue(forKey: key) }
            add("\(key).type") { $0[key] = .bool(true) }
        case .nestedInt(let object, let key):
            add("\(object).\(key).missing") { params in
                var value = params[object]?.objectValue ?? [:]
                value.removeValue(forKey: key)
                params[object] = .object(value)
            }
            add("\(object).\(key).type") { params in
                var value = params[object]?.objectValue ?? [:]
                value[key] = .bool(true)
                params[object] = .object(value)
            }
        case .stringEnum(let key, _):
            add("\(key).missing") { $0.removeValue(forKey: key) }
            add("\(key).type") { $0[key] = .bool(true) }
            add("\(key).enum") { $0[key] = .string("invalid-enum") }
        case .surfaceType(let key):
            add("\(key).missing") { $0.removeValue(forKey: key) }
            add("\(key).type") { $0[key] = .bool(true) }
            add("\(key).enum") { $0[key] = .string("invalid-surface") }
        case .uuidArray(let key):
            add("\(key).missing") { $0.removeValue(forKey: key) }
            add("\(key).type") { $0[key] = .bool(true) }
            add("\(key).uuid") { $0[key] = .array([.string("not-a-uuid")]) }
        case .stringArrayWithAtLeastOne(let key):
            add("\(key).missing") { $0.removeValue(forKey: key) }
            add("\(key).type") { $0[key] = .bool(true) }
            add("\(key).empty") { $0[key] = .array([]) }
            add("\(key).item") { $0[key] = .array([.bool(true)]) }
        case .uuidArrayWithAtLeastOne(let key):
            add("\(key).missing") { $0.removeValue(forKey: key) }
            add("\(key).type") { $0[key] = .bool(true) }
            add("\(key).empty") { $0[key] = .array([]) }
            add("\(key).uuid") { $0[key] = .array([.string("not-a-uuid")]) }
        case .surfaceSplitTarget:
            add("id/type.missing") { $0.removeValue(forKey: "id"); $0.removeValue(forKey: "type") }
            add("id/type.type") { $0["id"] = .bool(true); $0["type"] = .bool(true) }
            add("id/type.value") { $0["id"] = .string("not-a-uuid"); $0["type"] = .string("invalid-surface") }
        case .requiredSSHProfile:
            add("profile.destination.missing") { $0.removeValue(forKey: "destination"); $0.removeValue(forKey: "host"); $0.removeValue(forKey: "profile") }
            add("profile.destination.type") { $0.removeValue(forKey: "host"); $0.removeValue(forKey: "profile"); $0["destination"] = .bool(true) }
            add("profile.object.destination") { $0.removeValue(forKey: "destination"); $0["profile"] = .object([:]) }
        case .optionalSSHProfile:
            add("profile.object.destination") { $0["profile"] = .object([:]) }
        case .pushTokenContract:
            appendPushTokenProbes(valid: valid, to: &probes)
        case .threadActor:
            add("actor.missing") { $0.removeValue(forKey: "actor") }
            add("actor.type") { $0["actor"] = .string("bot") }
            add("actor.kind.enum") { $0["actor"] = .object(["kind": .string("user")]) }
            add("actor.bot_id.missing") { $0["actor"] = .object(["kind": .string("bot")]) }
            add("actor.bot_id.uuid") { $0["actor"] = .object(["kind": .string("bot"), "bot_id": .string("not-a-uuid")]) }
            add("execution_target.type") { $0["execution_target"] = .bool(true) }
            add("execution_target.enum") { $0["execution_target"] = .string("cloud") }
        }
        return probes
    }

    private static func appendPushTokenProbes(valid: [String: JSONValue], to probes: inout [PreflightProbe]) {
        func append(_ label: String, base: [String: JSONValue], _ mutate: (inout [String: JSONValue]) -> Void) {
            var params = base
            mutate(&params)
            probes.append(PreflightProbe(label: label, params: params))
        }
        append("push_token.missing", base: valid) { $0.removeValue(forKey: "push_token") }
        append("push_token.type", base: valid) { $0["push_token"] = .bool(true) }
        append("push_token.empty", base: valid) { $0["push_token"] = .string("") }
        append("push_token_type.missing", base: valid) { $0.removeValue(forKey: "push_token_type") }
        append("push_token_type.type", base: valid) { $0["push_token_type"] = .bool(true) }
        append("push_token_type.enum", base: valid) { $0["push_token_type"] = .string("invalid") }

        var typed = valid
        typed["token_purpose"] = .string("alert")
        typed["environment"] = .string("sandbox")
        typed["device_id"] = .string("device")
        typed["server_id"] = .string("server")
        for key in ["token_purpose", "environment", "device_id", "server_id"] {
            append("\(key).missing", base: typed) { $0.removeValue(forKey: key) }
            append("\(key).type", base: typed) { $0[key] = .bool(true) }
        }
        append("token_purpose.enum", base: typed) { $0["token_purpose"] = .string("invalid") }
        append("environment.enum", base: typed) { $0["environment"] = .string("invalid") }
        append("device_id.empty", base: typed) { $0["device_id"] = .string("") }
        append("server_id.empty", base: typed) { $0["server_id"] = .string("") }
        for key in ["boot_epoch", "activity_generation", "registration_revision"] {
            append("\(key).type", base: typed) { $0[key] = .bool(true) }
            append("\(key).range", base: typed) { $0[key] = .number(-1) }
        }
        append("contract_version.type", base: typed) { $0["contract_version"] = .bool(true) }
        append("contract_version.range", base: typed) { $0["contract_version"] = .number(0) }
        for key in ["activity_id", "activity_session_id"] {
            append("\(key).type", base: typed) { $0[key] = .bool(true) }
        }
        append("capabilities.type", base: typed) { $0["capabilities"] = .bool(true) }
        append("capabilities.items", base: typed) { $0["capabilities"] = .array([.bool(true)]) }
        var activity = typed
        activity["token_purpose"] = .string("activity_update")
        append("live_activity_token.missing", base: activity) { $0.removeValue(forKey: "live_activity_token") }
        append("live_activity_token.type", base: activity) { $0["live_activity_token"] = .bool(true) }
        append("live_activity_token.empty", base: activity) { $0["live_activity_token"] = .string("") }
        var v2 = typed
        v2["capabilities"] = .array([.string("live_activity_v2")])
        append("live_activity_v2.contract", base: v2) { $0["contract_version"] = .number(1) }
    }

    public static func businessParams(
        _ params: [String: JSONValue]
    ) -> [String: JSONValue] {
        params.filter { !transportParamKeys.contains($0.key) }
    }

    // PERF: every admitted host mutation hashes params. JSONEncoder is not
    // thread-safe — serialize concurrent hashes under a short lock and reuse
    // one encoder (sortedKeys + withoutEscapingSlashes match the prior
    // per-call setup so receipt idempotency digests stay identical).
    private static let paramsHashEncodeLock = NSLock()
    private static let paramsHashEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public static func paramsHash(
        method: String,
        _ params: [String: JSONValue]
    ) throws -> String {
        let business = JSONValue.object(businessParams(params))
        let encoded: Data = try {
            paramsHashEncodeLock.lock()
            defer { paramsHashEncodeLock.unlock() }
            return try paramsHashEncoder.encode(business)
        }()
        var input = Data("rc-command-v1\u{0}\(method)\u{0}".utf8)
        input.append(encoded)
        return hexDigest(SHA256.hash(data: input))
    }

    /// PERF: nibble table instead of per-byte `String(format:)` so every host
    /// mutation `params_hash` avoids 32 formatter calls while keeping the same
    /// CryptoKit lowercase hex contract used for receipt idempotency.
    private static let hexNibbleAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hexNibbleAlphabet[Int(byte >> 4)])
            out.append(hexNibbleAlphabet[Int(byte & 0x0f)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }
}

/// Bearer-owned mutation context for remote HTTP/WS command admission.
///
/// HTTP independence: `hostId` / `bootEpoch` are retained for diagnostics and
/// legacy call sites only. They are never mutation preconditions. Connection
/// registry callbacks are not consulted — authorization is bearer ownership +
/// `client_request_id` + method/params validation.
public struct MutationRequestContext: @unchecked Sendable {
    public let ownerFingerprint: String
    public let hostId: String
    public let bootEpoch: UInt64

    public init(
        ownerFingerprint: String,
        hostId: String,
        bootEpoch: UInt64,
        activeConnection: (@Sendable (String, String) -> Bool)? = nil
    ) {
        self.ownerFingerprint = ownerFingerprint
        self.hostId = hostId
        self.bootEpoch = bootEpoch
        _ = activeConnection
    }
}

/// A mutation failure raised before the request produced any effect.
///
/// Remote mutation admission releases the durable claim and returns the
/// wrapped error instead of recording a permanent `commandOutcomeUnknown`.
/// Throw it only from guards that run before the first write of the whole
/// request; an unmarked error keeps the conservative unknown outcome.
public struct DefiniteMutationRejection: Error {
    public let underlying: Error

    public init(_ underlying: Error) {
        self.underlying = underlying
    }
}

@MainActor
public protocol CommandReceiptStateRouting: AnyObject {
    func claimCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws -> CommandReceiptClaimResult
    func commitCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        result: JSONValue
    ) throws
    func finalizeCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        result: JSONValue,
        events: [EventBus.MutationEventIntent],
        minimumEventSequence: Int64
    ) throws -> [EventBus.Event]
    func markCommandReceiptUnknown(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws
    /// Deletes a still-`claimed` receipt whose request was definitely
    /// rejected before any effect, so the request id holds no outcome.
    func releaseCommandReceiptClaim(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws
    func commandReceiptStatus(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String
    ) throws -> CommandReceiptStatusResult
    /// C6: when non-nil, the dispatcher claims, commits and finalizes through
    /// this writer so receipt SQLite never runs on MainActor. Routers without
    /// one keep the synchronous methods above.
    var commandReceiptOffMainWriter: (any CommandReceiptOffMainWriting)? { get }
}

extension CommandReceiptStateRouting {
    public var commandReceiptOffMainWriter: (any CommandReceiptOffMainWriting)? { nil }
}

/// Durable receipt store that is safe to use off MainActor (C6).
///
/// `claim` and `commit` resume when their transaction has landed.
/// `finalizeTransaction` only builds the receipt + event transaction; the
/// caller hands it to `EventBus.enqueuePersistedCommit`, which runs it exactly
/// once on the delivery lane with the reserved sequence floor.
public protocol CommandReceiptOffMainWriting: Sendable {
    func claim(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) async throws -> CommandReceiptClaimResult
    func commit(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        result: JSONValue
    ) async throws
    func finalizeTransaction(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        result: JSONValue,
        events: [EventBus.MutationEventIntent]
    ) -> @Sendable (_ minimumEventSequence: Int64) throws -> [EventBus.Event]
}
