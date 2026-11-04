import Foundation
import CoreModel
import Persistence
import SocketServer

/// `scheduled_task.*`: the paired iPhone reads and edits the same Schedule Tasks
/// the Mac shows. Workspace tasks are `ScheduledTask` rows; Bot schedules stay
/// `bot.routine.*` and are only listed here so one screen shows both.
public enum ScheduledTaskRemoteWire {
    public static let methods: Set<String> = [
        "scheduled_task.save", "scheduled_task.delete", "scheduled_task.enable", "scheduled_task.run",
    ]
    public static let readMethods: Set<String> = ["scheduled_task.list"]

    static func encodeRule(_ rule: ScheduledFrequencyRule) -> JSONValue {
        .object([
            "frequency": .string(rule.frequency.rawValue),
            "scheduled_at": .number(rule.scheduledDate.timeIntervalSince1970),
            "interval_hours": .number(Double(rule.intervalHours)),
            "hour": .number(Double(rule.localTimeHour)),
            "minute": .number(Double(rule.localTimeMinute)),
            "weekdays": .array(rule.weekdays.map { .number(Double($0.rawValue)) }),
            "monthly_day": .number(Double(rule.monthlyDay)),
        ])
    }

    static func decodeRule(_ raw: JSONValue) throws -> ScheduledFrequencyRule {
        let value = raw.objectValue ?? [:]
        guard let raw = value["frequency"]?.stringValue, let frequency = ScheduledTaskFrequency(rawValue: raw) else {
            throw JSONRPCError.invalidParams
        }
        return ScheduledFrequencyRule(
            frequency: frequency,
            scheduledDate: value["scheduled_at"]?.intValue.map(Double.init).map(Date.init(timeIntervalSince1970:)) ?? Date().addingTimeInterval(3600),
            intervalHours: value["interval_hours"]?.intValue ?? 1,
            localTimeHour: value["hour"]?.intValue ?? 9,
            localTimeMinute: value["minute"]?.intValue ?? 0,
            weekdays: (value["weekdays"]?.arrayValue ?? []).compactMap { (day: JSONValue) in day.intValue.flatMap(ScheduledWeekday.init(rawValue:)) },
            monthlyDay: value["monthly_day"]?.intValue ?? 1
        )
    }

    static func effort(_ value: AgentEffortSelection?) -> JSONValue {
        guard let value else { return .null }
        return .string(value.effort?.rawValue ?? "auto")
    }

    static func effort(_ value: JSONValue?) -> AgentEffortSelection? {
        guard let raw = value?.stringValue else { return nil }
        return raw == "auto" ? .automatic : AgentReasoningEffort(rawValue: raw).map(AgentEffortSelection.fixed)
    }

    static func iso(_ date: Date?) -> JSONValue { date.map { .number($0.timeIntervalSince1970) } ?? .null }

    static func encodeTask(_ task: ScheduledTask, workspaceName: String?, active: ScheduledTaskRunStatus?) -> JSONValue {
        .object([
            "kind": .string("workspace"),
            "id": .string(task.id.uuidString.lowercased()),
            "title": .string(task.title),
            "prompt": .string(task.prompt),
            "workspace_id": .string(task.workspaceID.value.uuidString.lowercased()),
            "workspace_name": workspaceName.map(JSONValue.string) ?? .null,
            "run_as_user": .string(task.runAsUser),
            "provider": .string(task.provider.rawValue),
            "provider_instance_id": .string(task.providerInstanceID),
            "model": .string(task.model),
            "reasoning_effort": .string(task.reasoningEffort.rawValue),
            "reasoning_model": task.reasoningModel.map(JSONValue.string) ?? .null,
            "main_effort": effort(task.distillMainEffortSelection),
            "reasoning_model_effort": effort(task.distillReasoningEffortSelection),
            "ultracode": .bool(task.distillExecutionMode == .ultracode),
            "distill_mode": .string(task.distillExecutionMode.rawValue),
            "permission_mode": .string(task.permissionMode.rawValue),
            "plan_mode": .bool(task.interactionMode == .plan),
            "execution_mode": .string(task.executionMode.rawValue),
            "base_branch": task.baseBranch.map(JSONValue.string) ?? .null,
            "max_concurrent_runs": .number(Double(task.maxConcurrentRuns)),
            "frequencies": .array(task.recurrence.rules.map { encodeRule(ScheduledFrequencyRule(recurrence: $0)) }),
            "time_zone": .string(task.timeZoneIdentifier),
            "enabled": .bool(task.isEnabled),
            "next_run_at": iso(task.nextRunAt),
            "last_run_at": iso(task.lastRunAt),
            "active_run": active.map { .string($0.rawValue) } ?? .null,
        ])
    }

    static func encodeRoutine(_ routine: BotRoutine, bot: BotDefinition, workspaceID: WorkspaceID?) -> JSONValue {
        let spec = routine.definition.scheduleSpec
        return .object([
            "kind": .string("bot"),
            "id": .string(routine.definition.id.value.uuidString.lowercased()),
            "title": .string(routine.definition.name),
            "prompt": .string(routine.definition.prompt),
            "bot_id": .string(bot.id.value.uuidString.lowercased()),
            "bot_name": .string(bot.name),
            "bot_handle": .string(bot.handle),
            "bot_avatar": .string(bot.avatarSymbol),
            "workspace_id": workspaceID.map { .string($0.value.uuidString.lowercased()) } ?? .null,
            "schedule_spec_json": .string(routine.definition.scheduleSpecJSON),
            "summary": .string(spec?.displayNote() ?? routine.definition.scheduleNote),
            "ultracode": .bool(spec?.distillExecutionMode == .ultracode),
            "distill_mode": .string((spec?.distillExecutionMode ?? .auto).rawValue),
            "permission_mode": .string((spec?.permissionMode ?? .fullAccess).rawValue),
            "enabled": .bool(routine.activation.isEnabled),
        ])
    }
}

extension AppCommandRouter {
    public func listScheduledTasksRemote() throws -> JSONValue {
        guard let context else { throw JSONRPCError.internalError }
        let store = ScheduledTaskStore(db: context.db)
        let active = Dictionary(try store.listActiveRuns().map { ($0.taskID, $0.status) }, uniquingKeysWith: { first, _ in first })
        let names = Dictionary(uniqueKeysWithValues: context.state.workspaces.values.map { ($0.id, $0.name) })
        let tasks = try store.list().map {
            ScheduledTaskRemoteWire.encodeTask($0, workspaceName: names[$0.workspaceID], active: active[$0.id])
        }
        var routines: [JSONValue] = []
        for bot in try context.botStore.list() {
            let workspaceID = SidebarViewModel.scheduleWorkspace(
                for: bot, botStore: context.botStore, hostID: context.liveActivityHostIdentity.serverId)
            routines += try context.botStore.listRoutines(botID: bot.id).map {
                ScheduledTaskRemoteWire.encodeRoutine($0, bot: bot, workspaceID: workspaceID)
            }
        }
        return .object([
            "tasks": .array(tasks),
            "bot_tasks": .array(routines),
            "scheduler_active": .bool(SettingsStore(db: context.db).load().scheduledTasksActive),
            "workspaces": .array(context.state.workspaces.values.sorted { $0.name < $1.name }.map {
                .object(["id": .string($0.id.value.uuidString.lowercased()), "name": .string($0.name), "cwd": .string($0.cwd)])
            }),
            "users": .array(ScheduledSystemUserCatalog.eligibleUsers().map { .string($0.name) }),
        ])
    }

    /// Same validation and preflight as the Mac editor's Save.
    public func saveScheduledTaskRemote(params: [String: JSONValue]) async throws -> JSONValue {
        guard let context else { throw JSONRPCError.internalError }
        if params["bot_id"] != nil {
            guard let json = params["schedule_spec_json"]?.stringValue,
                  BotScheduleSpec.decodeJSON(json) != nil,
                  var object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                throw JSONRPCError(code: -32602, message: "Provide a valid Bot schedule.")
            }
            if let value = params["execution_destination"] {
                if value == .null {
                    object["executionDestination"] = NSNull()
                } else {
                    guard let raw = value.stringValue, let destination = BotExecutionDestination(storageValue: raw) else {
                        throw JSONRPCError(code: -32602, message: "Choose a valid execution destination.")
                    }
                    object["executionDestination"] = destination.storageValue
                }
            }
            var routine = params
            routine["name"] = params["title"] ?? params["name"]
            routine["routine_id"] = params["task_id"]
            // Keep absent keys distinct from explicit null until the shared
            // routine writer merges options an older client cannot edit.
            routine["schedule_spec_json"] = .string(String(
                decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self
            ))
            return try await dispatchPairedBotRemote(
                method: params["task_id"] == nil ? "bot.routine.create" : "bot.routine.update", params: routine)
        }
        if let raw = params["execution_destination"]?.stringValue, raw != "mac" {
            throw JSONRPCError(code: -32602, message: "Choose a Bot in Run as to schedule a VM run.")
        }
        guard let rawWorkspace = params["workspace_id"]?.stringValue, let workspaceUUID = UUID(uuidString: rawWorkspace),
              let workspace = context.state.workspaces[WorkspaceID(workspaceUUID)] else {
            throw JSONRPCError(code: -32602, message: "Select a workspace.")
        }
        let store = ScheduledTaskStore(db: context.db)
        let existing = try params["task_id"]?.stringValue.flatMap(UUID.init).flatMap { try store.get(id: $0) }
        if params["task_id"] != nil, existing == nil { throw JSONRPCError(code: -32044, message: "This scheduled task no longer exists.") }
        var draft = ScheduledTaskEditorDraft(task: existing)
        draft.title = params["title"]?.stringValue ?? draft.title
        draft.prompt = params["prompt"]?.stringValue ?? draft.prompt
        draft.workspaceID = workspace.id
        draft.workspacePathSnapshot = workspace.cwd
        if let value = params["run_as_user"] {
            guard let user = value.stringValue, let resolved = ScheduledSystemUserCatalog.user(named: user) else {
                throw JSONRPCError(code: -32602, message: "Select an eligible system user.")
            }
            draft.runAsUser = resolved.name
            draft.runAsUID = resolved.uid
        }
        if let raw = params["provider"]?.stringValue, let provider = AgentProvider(rawValue: raw), provider != draft.provider {
            draft.provider = provider
            draft.providerInstanceID = provider.rawValue
        }
        draft.providerInstanceID = params["provider_instance_id"]?.stringValue ?? draft.providerInstanceID
        draft.model = params["model"]?.stringValue ?? draft.model
        if let raw = params["reasoning_effort"]?.stringValue, let effort = AgentReasoningEffort(rawValue: raw) { draft.reasoningEffort = effort }
        if params["reasoning_model"] != nil { draft.reasoningModel = params["reasoning_model"]?.stringValue }
        if params["main_effort"] != nil { draft.distillMainEffortSelection = ScheduledTaskRemoteWire.effort(params["main_effort"]) }
        if params["reasoning_model_effort"] != nil {
            draft.distillReasoningEffortSelection = ScheduledTaskRemoteWire.effort(params["reasoning_model_effort"])
        }
        if let raw = params["distill_mode"]?.stringValue, let mode = DistillExecutionMode(rawValue: raw) {
            draft.distillExecutionMode = mode
        } else if let legacy = params["ultracode"]?.boolValue {
            draft.distillExecutionMode = legacy ? .ultracode : .normal
        }
        if let raw = params["permission_mode"]?.stringValue, let mode = AgentPermissionMode(rawValue: raw) { draft.permissionMode = mode }
        if let plan = params["plan_mode"]?.boolValue { draft.interactionMode = plan ? .plan : .default }
        if let raw = params["execution_mode"]?.stringValue, let mode = AgentExecutionMode(rawValue: raw) { draft.executionMode = mode }
        if let value = params["base_branch"] { draft.baseBranch = value.stringValue ?? "" }
        if let value = params["max_concurrent_runs"]?.intValue { draft.maxConcurrentRuns = min(max(value, 1), 5) }
        if let rules = params["frequencies"]?.arrayValue { draft.frequencyRules = try rules.map(ScheduledTaskRemoteWire.decodeRule) }
        draft.timeZoneIdentifier = params["time_zone"]?.stringValue ?? draft.timeZoneIdentifier
        draft.isEnabled = params["enabled"]?.boolValue ?? draft.isEnabled
        let task: ScheduledTask
        do {
            task = try draft.makeTask()
            _ = try await ScheduledTaskExecutor(context: context, router: self).preflight(task)
        } catch {
            throw JSONRPCError(code: -32602, message: String(describing: error))
        }
        try store.save(task)
        ScheduledTaskCrossProcess.notifyStoreChanged(reason: "remote_save")
        if task.isEnabled { scheduledTaskScheduler?.tick() }
        return ScheduledTaskRemoteWire.encodeTask(task, workspaceName: workspace.name, active: nil)
    }

    public func deleteScheduledTaskRemote(id: UUID) throws -> JSONValue {
        guard let context else { throw JSONRPCError.internalError }
        do { try ScheduledTaskStore(db: context.db).delete(id: id) } catch {
            throw JSONRPCError(code: -32602, message: String(describing: error))
        }
        ScheduledTaskCrossProcess.notifyStoreChanged(reason: "remote_delete")
        return .object(["deleted": .bool(true), "task_id": .string(id.uuidString.lowercased())])
    }

    public func enableScheduledTaskRemote(id: UUID, enabled: Bool) async throws -> JSONValue {
        guard let context else { throw JSONRPCError.internalError }
        let store = ScheduledTaskStore(db: context.db)
        guard let task = try store.get(id: id) else { throw JSONRPCError(code: -32044, message: "This scheduled task no longer exists.") }
        if enabled {
            do { _ = try await ScheduledTaskExecutor(context: context, router: self).preflight(task) } catch {
                throw JSONRPCError(code: -32602, message: String(describing: error))
            }
            try store.setEnabled(id: id, enabled: true, nextRunAt: task.calculatedNextRun(after: Date().addingTimeInterval(-0.001)))
            scheduledTaskScheduler?.tick()
        } else {
            try store.setEnabled(id: id, enabled: false, nextRunAt: nil)
        }
        ScheduledTaskCrossProcess.notifyStoreChanged(reason: "remote_enable")
        return .object(["task_id": .string(id.uuidString.lowercased()), "enabled": .bool(enabled)])
    }

    public func runScheduledTaskRemote(id: UUID) throws -> JSONValue {
        guard let scheduler = scheduledTaskScheduler else {
            throw JSONRPCError(code: -32045, message: "The in-app scheduler is not ready yet. Keep MacCode open and retry.")
        }
        let claim: ScheduledTaskClaim
        do { claim = try scheduler.claimAndRunNow(taskID: id) } catch {
            throw JSONRPCError(code: -32602, message: String(describing: error))
        }
        return .object(["task_id": .string(id.uuidString.lowercased()), "run_id": .string(claim.run.id.uuidString.lowercased()), "queued": .bool(true)])
    }
}
