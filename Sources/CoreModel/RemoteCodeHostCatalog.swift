import CryptoKit
import Foundation
import os

/// Named host catalog admitted through `remotecode-bot-self-config`.
///
/// `rc_host_call` is the one generic tool: the host admits it only for an
/// active run of Titio, the built-in RemoteCode assistant, so Titio can do
/// anything the RemoteCode UI can. Mutations require a provider-supplied
/// `operation_id` which the MCP child maps onto the durable command-receipt
/// `client_request_id`.
public enum RemoteCodeHostCatalog: Sendable {
    public static let workspaceCreate = "rc_workspace_create"
    public static let workspaceList = "rc_workspace_list"
    public static let threadCreate = "rc_thread_create"
    public static let threadList = "rc_thread_list"
    public static let botCreate = "rc_bot_create"
    public static let botList = "rc_bot_list"
    public static let botOpen = "rc_bot_open"
    public static let botSend = "rc_bot_send"
    public static let botThreadCreate = "rc_bot_thread_create"
    public static let botSkillCreate = "rc_bot_skill_create"
    public static let botSkillView = "rc_bot_skill_view"
    public static let activityList = "rc_activity_list"
    public static let hostHelp = "rc_host_help"
    public static let hostBatch = "rc_host_batch"
    public static let botDelegate = "rc_bot_delegate"
    public static let scheduledTaskRunNext = "rc_scheduled_task_run_next"
    public static let browserScreenshot = "rc_browser_screenshot"

    // Keep managed-provider calls on a private namespace. The owner-only socket
    // is also used by RC2CLI, whose legacy workspace/thread methods intentionally
    // do not carry provider-run credentials.
    public static let workspaceCreateRPC = "host.workspace.create"
    public static let workspaceListRPC = "host.workspace.list"
    public static let threadCreateRPC = "host.agent.thread.create"
    public static let threadListRPC = "host.agent.thread.list"
    public static let botCreateRPC = "host.bot.create"
    public static let botListRPC = "host.bot.list"
    public static let botOpenRPC = "host.bot.open"
    public static let botSendRPC = "host.bot.send"
    public static let botThreadCreateRPC = "host.bot.thread.create"
    public static let botSkillCreateRPC = "host.bot.skill.create"
    public static let botSkillViewRPC = "host.bot.skill.view"
    public static let activityListRPC = "host.activity.list"
    public static let hostHelpRPC = "host.help"
    public static let hostBatchRPC = "host.batch"
    public static let botDelegateRPC = "host.bot.delegate"
    public static let scheduledTaskRunNextRPC = "host.scheduled_task.run_next"
    public static let browserScreenshotRPC = "host.browser.screenshot"
    public static let hostCallRPC = "host.call"

    public static let operationIDKey = "operation_id"
    public static let genericHostCallTool = "rc_host_call"

    /// Bounded Unix-server deadline for every catalog RPC. Ordinary local IPC
    /// stays on the 5s default; catalog hops can wait on MainActor while Bot
    /// Desk paints self-sizing chat rows.
    public static let unixServerDeadline: TimeInterval = 120
    /// Slack so the MCP child does not declare timeout while the host is still
    /// inside `unixServerDeadline`.
    public static let unixClientDeadlineSlack: TimeInterval = 5
    public static var unixClientDeadline: TimeInterval {
        unixServerDeadline + unixClientDeadlineSlack
    }

    public static func usesUnixCatalogDeadline(_ method: String) -> Bool {
        rpcMethods.contains(method)
    }

    public static let providerDirective = """
    Parallel Bot tasks: when you are running as a Bot and have independent work, use rc_bot_send with your own bot_id and omit conversation_id to start each task in a fresh conversation. You can start several independent tasks without waiting; the host records a task link in this chat that opens the task alongside it. Use a focused text for each task. Never send the task back to the active conversation, recursively multiply tasks, or run simultaneous edits against the same files. Preserve current execution context, model, effort and permissions. The returned run_id and conversation_id identify the accepted task, not completion. Observe Activity or the task conversation before claiming success. Ordinary agents retain their existing behavior.

    Built-in RemoteCode intents (create or list workspaces, Agent App threads, Bots, Bot desk threads, and owned Bot skills) must call the named tools \(workspaceCreate), \(workspaceList), \(threadCreate), \(threadList), \(botCreate), \(botList), \(botOpen), \(botSend), \(botThreadCreate), \(botSkillCreate), and \(botSkillView). To answer what is happening in RemoteCode (running or idle threads, Bots, scheduled tasks, items that need the user) call \(activityList). To ask another Bot by name to do something call \(botDelegate). To fire a workspace's next scheduled task now call \(scheduledTaskRunNext); for a named routine first inspect scheduled_task.list and run its exact task/routine id. To capture the Mac browser into the calling Agent thread, call \(browserScreenshot); it accepts optional surface_id and reason, and requires operation_id. For a consulted Bot's skill files, use \(botSkillCreate) and \(botSkillView); `bot_write_home_file` is only for the calling Bot's own home. Titio alone may call \(genericHostCallTool) to run any RemoteCode JSON-RPC method the app UI uses. Discover interaction topics, methods and parameter guidance with \(hostHelp) before constructing unfamiliar calls; prefer a named tool when one fits. Other Bots must not call \(genericHostCallTool). Do not use Computer Use, macos-harness, Accessibility (AX), or clicking the RemoteCode UI as a fallback for these intents. Every mutation must supply a unique `operation_id`. If a mutation reply is lost, read back with the matching list/view tool instead of retrying with a new id.
    For Activity, pass section/outcome/workspace_id/search and follow cursor; include_context:true loads the full inventory and notification options. For "continue all interrupted conversations", filter section=needs_you and outcome=interrupted, collect pages, then Titio uses rc_host_batch with agent.run.continue for the exact thread ids. rc_host_batch accepts independent calls, each with its own operation_id; every result/error must be checked. Do not wait for one independent run to finish before starting the next.
    """

    public static var toolNames: [String] {
        [
            workspaceCreate, workspaceList,
            threadCreate, threadList,
            botCreate, botList, botOpen, botSend, botThreadCreate,
            botSkillCreate, botSkillView,
            activityList, hostHelp, hostBatch, botDelegate, scheduledTaskRunNext, browserScreenshot,
            genericHostCallTool,
        ]
    }

    public static let mutationToolNames: Set<String> = [
        workspaceCreate, threadCreate, botCreate, botOpen, botSend, botThreadCreate, botSkillCreate,
        botDelegate, scheduledTaskRunNext, browserScreenshot, genericHostCallTool,
    ]

    public static let rpcMethods: Set<String> = [
        workspaceCreateRPC, workspaceListRPC,
        threadCreateRPC, threadListRPC,
        botCreateRPC, botListRPC, botOpenRPC, botSendRPC, botThreadCreateRPC,
        botSkillCreateRPC, botSkillViewRPC,
        activityListRPC, hostHelpRPC, hostBatchRPC, botDelegateRPC, scheduledTaskRunNextRPC, browserScreenshotRPC,
        hostCallRPC,
    ]

    public static let rpcMutationMethods: Set<String> = [
        workspaceCreateRPC, threadCreateRPC,
        botCreateRPC, botOpenRPC, botSendRPC, botThreadCreateRPC, botSkillCreateRPC,
        botDelegateRPC, scheduledTaskRunNextRPC, browserScreenshotRPC, hostCallRPC,
    ]

    public static func rpcMethod(for tool: String) -> String? {
        switch tool {
        case workspaceCreate: return workspaceCreateRPC
        case workspaceList: return workspaceListRPC
        case threadCreate: return threadCreateRPC
        case threadList: return threadListRPC
        case botCreate: return botCreateRPC
        case botList: return botListRPC
        case botOpen: return botOpenRPC
        case botSend: return botSendRPC
        case botThreadCreate: return botThreadCreateRPC
        case botSkillCreate: return botSkillCreateRPC
        case botSkillView: return botSkillViewRPC
        case activityList: return activityListRPC
        case hostHelp: return hostHelpRPC
        case hostBatch: return hostBatchRPC
        case botDelegate: return botDelegateRPC
        case scheduledTaskRunNext: return scheduledTaskRunNextRPC
        case browserScreenshot: return browserScreenshotRPC
        case genericHostCallTool: return hostCallRPC
        default: return nil
        }
    }

    public static func isMutation(_ tool: String) -> Bool {
        mutationToolNames.contains(tool)
    }

    public static func toolCatalog() -> [[String: Any]] {
        toolNames.map { name in
            [
                "name": name,
                "description": description(for: name),
                "inputSchema": schema(for: name),
            ]
        }
    }

    public static func description(for name: String) -> String {
        switch name {
        case workspaceCreate:
            return "Create a RemoteCode workspace through the live host. Requires operation_id. Do not use Computer Use or macos-harness for this."
        case workspaceList:
            return "List RemoteCode workspaces through the live host."
        case threadCreate:
            return "Create an Agent App thread through the live host. Requires operation_id. Do not use Computer Use or macos-harness for this."
        case threadList:
            return "List Agent App threads through the live host."
        case botCreate:
            return "Create a RemoteCode Bot through the live host. The returned Bot id is granted only to this authenticated active run. Requires operation_id. Do not use Computer Use or macos-harness for this."
        case botList:
            return "List RemoteCode Bots through the live host."
        case botOpen:
            return "Open a RemoteCode Bot Desk through the live host. Requires operation_id."
        case botSend:
            return "Send a message to one RemoteCode Bot Desk through the live host. Returns after persist and enqueue. Requires operation_id."
        case botThreadCreate:
            return "Create a Desk thread for one RemoteCode Bot through the live host. Requires operation_id."
        case botSkillCreate:
            return "Create skills/<slug>/SKILL.md on a Bot this authenticated run created or consulted, or on the calling Bot. Requires operation_id. Returns body and digest."
        case botSkillView:
            return "Read skills/<slug>/SKILL.md for a Bot this authenticated run created or consulted, or the calling Bot. Returns body and digest so the exact contents can be proven."
        case activityList:
            return "Read canonical MacCode Activity with filters and pagination. For interrupted conversations use section=needs_you, outcome=interrupted. Returns activity items, counts and next_cursor. Set include_context=true only when you also need workspaces, threads, Bots, schedules or exact notification options."
        case hostHelp:
            return "Discover MacCode controls without guessing. Use topic for a workflow, query to search methods/topics, or method for its host validation requirements and related workflows. No arguments lists all controls. Read-only; no operation_id."
        case hostBatch:
            return "Titio only. Execute 1–20 independent host calls in one tool round trip, for example continue several interrupted threads, stop runs, or update schedules. Each call requires its own unique operation_id and uses the same authorization and durable receipt as rc_host_call. Returns a result or error for EVERY call; failures do not cancel other calls. Never batch dependent steps or infer completion from acceptance. Reuse each operation_id when retrying that same call."
        case botDelegate:
            return "Ask another RemoteCode Bot, by id, exact name or handle, to do something. Ambiguous names are rejected. Sends the text to that Bot's conversation and returns after persist and enqueue, not after task completion. Requires operation_id."
        case scheduledTaskRunNext:
            return "Run a workspace's next scheduled task now through the in-app scheduler. The workspace is a name or id; task_id optionally picks a specific task in it. Requires operation_id."
        case browserScreenshot:
            return "Capture the Mac browser and add its screenshot to the authenticated calling Agent thread. Optional surface_id selects the browser surface; reason is a short explanation. Requires operation_id."
        case genericHostCallTool:
            return "Titio only. Run a MacCode JSON-RPC method through the same host controls as the UI. Use rc_host_help for unfamiliar calls. host_id and client_request_id are filled in by the host. Requires operation_id for every call. Read-only calls work in supervised mode; mutations require Full Access. Use rc_host_batch for independent calls. Read back mutations; accepted/queued is not completion."
        default:
            return name
        }
    }

    public static func schema(for name: String) -> [String: Any] {
        let operationID: [String: Any] = [
            operationIDKey: [
                "type": "string",
                "description": "Caller-supplied idempotency key. Replaying the same id with the same arguments returns the prior result.",
            ]
        ]
        switch name {
        case workspaceCreate:
            return objectSchema(
                properties: operationID.merging([
                    "name": ["type": "string"],
                    "cwd": ["type": "string"],
                ]) { _, new in new },
                required: [operationIDKey]
            )
        case workspaceList:
            return objectSchema(properties: [:], required: [])
        case threadCreate:
            return objectSchema(
                properties: operationID.merging([
                    "title": ["type": "string"],
                    "workspace_id": ["type": "string"],
                    "provider": ["type": "string"],
                    "model": ["type": "string"],
                    "permission_mode": ["type": "string"],
                ]) { _, new in new },
                required: [operationIDKey]
            )
        case threadList:
            return objectSchema(
                properties: ["workspace_id": ["type": "string"]],
                required: []
            )
        case botCreate:
            return objectSchema(
                properties: operationID.merging([
                    "name": ["type": "string"],
                    "title": ["type": "string"],
                    "description": ["type": "string"],
                    "handle": ["type": "string"],
                    "soul": ["type": "string"],
                ]) { _, new in new },
                required: ["name", operationIDKey]
            )
        case botList:
            return objectSchema(properties: [:], required: [])
        case botOpen:
            return objectSchema(
                properties: operationID.merging([
                    "bot_id": ["type": "string"],
                ]) { _, new in new },
                required: ["bot_id", operationIDKey]
            )
        case botSend:
            return objectSchema(
                properties: operationID.merging([
                    "bot_id": ["type": "string"],
                    "text": ["type": "string"],
                    "conversation_id": ["type": "string"],
                ]) { _, new in new },
                required: ["bot_id", "text", operationIDKey]
            )
        case botThreadCreate:
            return objectSchema(
                properties: operationID.merging([
                    "bot_id": ["type": "string"],
                    "title": ["type": "string"],
                ]) { _, new in new },
                required: ["bot_id", operationIDKey]
            )
        case botSkillCreate:
            return objectSchema(
                properties: operationID.merging([
                    "bot_id": ["type": "string"],
                    "skill_id": ["type": "string", "description": "Catalog slug for skills/<slug>/SKILL.md."],
                    "body": ["type": "string", "description": "Full SKILL.md body. Omit to create the default owned skill template."],
                ]) { _, new in new },
                required: ["bot_id", "skill_id", operationIDKey]
            )
        case botSkillView:
            return objectSchema(
                properties: [
                    "bot_id": ["type": "string"],
                    "skill_id": ["type": "string", "description": "Catalog slug for skills/<slug>/SKILL.md."],
                ],
                required: ["bot_id", "skill_id"]
            )
        case activityList:
            return objectSchema(properties: [
                "section": ["type": "string", "enum": ["all", "running", "needs_you", "just_finished", "finished"]],
                "outcome": ["type": "string", "enum": ["completed", "failed", "interrupted", "stopped"]],
                "workspace_id": ["type": "string", "format": "uuid"],
                "search": ["type": "string"],
                "since": ["type": "string", "description": "ISO 8601 timestamp."],
                "cursor": ["type": "string"],
                "limit": ["type": "integer", "minimum": 1, "maximum": 500],
                "include_context": ["type": "boolean", "default": false],
            ], required: [])
        case hostHelp:
            return objectSchema(
                properties: [
                    "topic": ["type": "string", "enum": TitioCapabilities.topics.map(\.id)],
                    "query": ["type": "string"],
                    "method": ["type": "string"],
                ],
                required: []
            )
        case hostBatch:
            return objectSchema(properties: [
                "calls": [
                    "type": "array", "minItems": 1, "maxItems": 20,
                    "items": schema(for: genericHostCallTool),
                ],
            ], required: ["calls"])
        case botDelegate:
            return objectSchema(
                properties: operationID.merging([
                    "bot": ["type": "string", "description": "Bot id, exact name or handle, for example developer."],
                    "text": ["type": "string"],
                    "conversation_id": ["type": "string"],
                ]) { _, new in new },
                required: ["bot", "text", operationIDKey]
            )
        case scheduledTaskRunNext:
            return objectSchema(
                properties: operationID.merging([
                    "workspace": ["type": "string", "description": "Workspace name or id."],
                    "task_id": ["type": "string"],
                ]) { _, new in new },
                required: ["workspace", operationIDKey]
            )
        case genericHostCallTool:
            return objectSchema(
                properties: operationID.merging([
                    "method": ["type": "string", "description": "RemoteCode JSON-RPC method, for example bot.save."],
                    "params": ["type": "object", "description": "The method's params.", "additionalProperties": true],
                ]) { _, new in new },
                required: ["method", operationIDKey]
            )
        case browserScreenshot:
            return objectSchema(
                properties: operationID.merging([
                    "surface_id": ["type": "string", "format": "uuid"],
                    "reason": ["type": "string", "maxLength": 500],
                ]) { _, new in new },
                required: [operationIDKey]
            )
        default:
            return objectSchema(properties: [:], required: [])
        }
    }

    public static func bodyDigest(_ body: String) -> String {
        let digest = SHA256.hash(data: Data(body.utf8))
        var hex = [UInt8]()
        hex.reserveCapacity(64)
        let alphabet = Array("0123456789abcdef".utf8)
        for byte in digest {
            hex.append(alphabet[Int(byte >> 4)])
            hex.append(alphabet[Int(byte & 0x0f)])
        }
        return String(bytes: hex, encoding: .utf8) ?? ""
    }

    public static func allowedClaudeTools(serverName: String) -> [String] {
        toolNames.map { "mcp__\(serverName)__\($0)" }
    }

    private static func objectSchema(properties: [String: Any], required: [String]) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "additionalProperties": false,
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return schema
    }
}

public enum RemoteCodeHostCatalogDiagnostics {
    public static let log = Logger(subsystem: "io.remotecode.agent", category: "host-catalog")

    public static func authorization(
        decision: String,
        method: String,
        runID: String,
        threadID: String,
        receiptID: String? = nil,
        permission: String? = nil
    ) {
        log.info("host.auth method=\(method, privacy: .public) run=\(runID, privacy: .private(mask: .hash)) thread=\(threadID, privacy: .private(mask: .hash)) decision=\(decision, privacy: .public) receipt=\(receiptID ?? "-", privacy: .private(mask: .hash)) permission=\(permission ?? "-", privacy: .public)")
    }

    public static func timeout(method: String, budget: String, elapsedMilliseconds: Int) {
        log.info("host.rpc.timeout method=\(method, privacy: .public) budget=\(budget, privacy: .public) elapsed_ms=\(elapsedMilliseconds, privacy: .public)")
    }

    public static func receipt(decision: String, method: String, operationID: String) {
        log.info("host.receipt method=\(method, privacy: .public) operation=\(operationID, privacy: .private(mask: .hash)) decision=\(decision, privacy: .public)")
    }
}
