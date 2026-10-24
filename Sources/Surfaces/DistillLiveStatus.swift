import Foundation
import CoreModel
import AgentRuntime

/// Live Distill ACP status (compaction, model, subagents) folded from
/// `providerRuntime` events so the running strip can mirror the Distill TUI.
/// Pure value type: only runtime events touch it, never per-token events.
public struct DistillLiveStatus: Equatable, Sendable {
    public struct Subagent: Equatable, Sendable, Identifiable {
        public var id: String
        public var childSessionId: String?
        public var type: String
        public var description: String
        public var model: String?
        public var effort: String?
        public var tokensUsed: Int
        public var durationMs: Int
        public var receivedAt: Date
        public var compactingSince: Date?
        /// `completed` / `failed` / `cancelled` once the subagent ended.
        public var finishedStatus: String?

        public var isActive: Bool { finishedStatus == nil }
        public var isCompacting: Bool { isActive && compactingSince != nil }

        /// "general-purpose" → "General", "explore" → "Explore".
        public var typeLabel: String {
            let first = type.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " }).first.map(String.init) ?? type
            guard let head = first.first else { return "Agent" }
            return head.uppercased() + first.dropFirst()
        }

        public var phaseText: String {
            switch finishedStatus {
            case nil: return isCompacting ? "Compacting" : "Running"
            case "completed": return "Done"
            case "failed": return "Failed"
            case "cancelled": return "Cancelled"
            default: return "Done"
            }
        }

        /// Model without its provider prefix ("meta/muse-spark" → "muse-spark").
        public var shortModel: String? {
            guard let model, !model.isEmpty else { return nil }
            return model.split(separator: "/").last.map(String.init) ?? model
        }

        public func elapsedSeconds(now: Date) -> Int {
            let base = max(0, durationMs) / 1000
            guard isActive else { return base }
            return base + max(0, Int(now.timeIntervalSince(receivedAt)))
        }
    }

    /// `/goal` progress folded from `goal_updated`.
    public struct Goal: Equatable, Sendable {
        public var id: String
        public var objective: String
        /// active / user_paused / back_off_paused / no_progress_paused / infra_paused / blocked / budget_limited / complete
        public var status: String
        /// idle / planning / executing
        public var phase: String
        public var tokensUsed: Int
        public var tokenBudget: Int?
        public var elapsedMs: Int
        public var rounds: Int

        public var isActive: Bool { status == "active" }

        /// "Goal: <objective> — <phase>"
        public var headline: String { "Goal: \(objective) — \(phase)" }

        /// "12k / 100k" or "12k" without a budget.
        public var tokensText: String {
            let used = DistillLiveStatus.formatTokens(tokensUsed)
            guard let tokenBudget, tokenBudget > 0 else { return used }
            return "\(used) / \(DistillLiveStatus.formatTokens(tokenBudget))"
        }
    }

    /// `/loop` task folded from `scheduled_task_*`.
    public struct ScheduledTask: Equatable, Sendable, Identifiable {
        public var id: String
        public var prompt: String
        public var humanSchedule: String?
        public var lastFiredAt: Date?
    }

    public struct Operation: Equatable, Sendable {
        public var id: String
        public var sequence: Int
        public var revision: Int
        public var label: String
        public var stalled: Bool
        public var lastProgressAt: Date
        public var phaseStartedAt: Date
    }
    public var operation: Operation?

    public func operationHeadline(now: Date) -> String? {
        guard guestRecoveryText == nil, let operation else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(operation.lastProgressAt)))
        if operation.stalled { return "\(operation.label) — no progress for \(seconds)s · Stop to cancel" }
        return "\(operation.label) — last update \(seconds)s ago"
    }

    public static let maxSubagents = 50
    public static let maxScheduledTasks = 50

    /// Run these events belong to; the owner resets the value when it changes.
    public var runId: AgentRunID?
    public var mainCompactingSince: Date?
    public var model: String?
    public var effort: String?
    public var subagents: [Subagent] = []
    public var goal: Goal?
    public var scheduledTasks: [ScheduledTask] = []
    /// Guest run startup ("Starting Linux agent…") until its agent is up.
    public var guestStage: DistillGuestStage?
    public var guestStageSince: Date?

    public init(runId: AgentRunID? = nil) {
        self.runId = runId
    }

    public var compactingSubagent: Subagent? {
        subagents.last(where: { $0.isCompacting })
    }

    private var guestRecoveryText: String? {
        switch guestStage {
        case .diagnosing, .repairing, .verifying, .recovered, .repairFailed: return guestStage?.text
        default: return nil
        }
    }

    /// "Subagent (<description>): Compacting…" / "Compacting…" / nil (keep existing copy).
    public var headline: String? {
        if let guestRecoveryText { return guestRecoveryText }
        if let operation { return operation.stalled ? "\(operation.label) — no progress" : operation.label }
        if let sub = compactingSubagent { return "Subagent (\(sub.description)): Compacting…" }
        if mainCompactingSince != nil { return "Compacting…" }
        if let text = guestStage?.text { return text }
        return nil
    }

    /// Goal headline while a goal is actively running (compaction headline wins).
    public var goalHeadline: String? {
        guard headline == nil, let goal, goal.isActive else { return nil }
        return goal.headline
    }

    /// Start of the compaction the headline describes.
    public var headlineSince: Date? {
        if guestRecoveryText != nil { return guestStageSince }
        return compactingSubagent?.compactingSince ?? mainCompactingSince
            ?? (guestStage?.text != nil ? guestStageSince : nil)
    }

    /// "<model> <effort>" of whoever the headline describes (else the main agent).
    public var modelEffortText: String? {
        let sub = compactingSubagent
        let name = sub != nil ? sub?.model : model
        let level = sub != nil ? sub?.effort : effort
        let text = [name, level].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    public var isEmpty: Bool {
        headline == nil && modelEffortText == nil && subagents.isEmpty
            && goal == nil && scheduledTasks.isEmpty
    }

    /// 135000 → "135k", 1500 → "1.5k", 950 → "950".
    public static func formatTokens(_ n: Int) -> String {
        func scaled(_ value: Double, _ suffix: String) -> String {
            let rounded = (value * 10).rounded() / 10
            return rounded == rounded.rounded()
                ? "\(Int(rounded))\(suffix)"
                : String(format: "%.1f%@", rounded, suffix)
        }
        if n < 1_000 { return "\(max(0, n))" }
        if n < 10_000 { return scaled(Double(n) / 1_000, "k") }
        if n < 1_000_000 { return "\(n / 1_000)k" }
        return scaled(Double(n) / 1_000_000, "M")
    }

    public static func isCarrierMethod(_ method: String) -> Bool {
        ProviderRuntimeEvent.isLiveStatusCarrier(method: method)
    }

    /// Fold one Distill runtime event. Unrelated methods/kinds are ignored.
    public mutating func apply(method: String, payloadJSON: String, receivedAt: Date = Date()) {
        guard Self.isCarrierMethod(method),
              let data = payloadJSON.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if method == "_remotecode/operation" {
            guard let id = payload["operationId"] as? String,
                  let sequence = payload["sequence"] as? Int,
                  let revision = payload["revision"] as? Int,
                  revision > (operation?.revision ?? 0),
                  let phase = payload["phase"] as? String,
                  let age = payload["lastProgressAgeMs"] as? Double, age.isFinite, age >= 0,
                  let elapsed = payload["phaseElapsedMs"] as? Double, elapsed.isFinite, elapsed >= 0 else { return }
            let label: String
            switch phase {
            case "loading_configuration": label = "Loading configuration"
            case "preparing_session": label = "Preparing conversation"
            case "waiting_model": label = "Waiting for model"
            case "executing_tool": label = "Running tool"
            case "waiting_authorization": label = "Waiting for authorization"
            default: return
            }
            var lastProgress = receivedAt.addingTimeInterval(-age / 1000)
            if let previous = operation, previous.id == id {
                guard sequence >= previous.sequence else { return }
                if sequence == previous.sequence { lastProgress = min(lastProgress, previous.lastProgressAt) }
            }
            operation = Operation(id: id, sequence: sequence, revision: revision, label: label,
                stalled: payload["stalled"] as? Bool ?? false, lastProgressAt: lastProgress,
                phaseStartedAt: receivedAt.addingTimeInterval(-elapsed / 1000))
            return
        }
        if method == DistillGuestStage.runtimeMethod {
            guard let stage = (payload["stage"] as? String).flatMap(DistillGuestStage.init(rawValue:)) else { return }
            if stage != guestStage { guestStageSince = receivedAt }
            guestStage = stage == .ready ? nil : stage
            if stage == .ready { guestStageSince = nil }
            return
        }
        let update: [String: Any]
        if let nested = payload["update"] as? [String: Any] {
            update = nested
        } else if payload["sessionUpdate"] != nil {
            update = payload
        } else {
            // Plain ACP kind carried as the method name with fields at the root.
            var rebuilt = payload
            rebuilt["sessionUpdate"] = method
            update = rebuilt
        }
        let sessionId = payload["sessionId"] as? String ?? update["sessionId"] as? String
        guard let kind = update["sessionUpdate"] as? String else { return }

        switch kind {
        case "auto_compact_started":
            setCompacting(sessionId: sessionId, since: receivedAt)
        case "auto_compact_completed", "auto_compact_failed", "auto_compact_cancelled":
            setCompacting(sessionId: sessionId, since: nil)
        case "subagent_spawned":
            guard let id = Self.string(update["subagent_id"]) ?? Self.string(update["child_session_id"]) else { return }
            var sub = subagent(id: id, receivedAt: receivedAt)
            sub.childSessionId = Self.string(update["child_session_id"]) ?? sub.childSessionId
            sub.type = Self.string(update["subagent_type"]) ?? sub.type
            sub.description = Self.string(update["description"]) ?? sub.description
            sub.model = Self.string(update["model"]) ?? sub.model
            sub.receivedAt = receivedAt
            store(sub)
        case "subagent_progress":
            guard let id = Self.string(update["subagent_id"]) ?? Self.string(update["child_session_id"]) else { return }
            var sub = subagent(id: id, receivedAt: receivedAt)
            sub.childSessionId = Self.string(update["child_session_id"]) ?? sub.childSessionId
            sub.durationMs = Self.int(update["duration_ms"]) ?? sub.durationMs
            sub.tokensUsed = Self.int(update["tokens_used"]) ?? sub.tokensUsed
            sub.model = Self.string(update["active_model"]) ?? sub.model
            sub.effort = Self.string(update["active_reasoning_effort"]) ?? sub.effort
            sub.receivedAt = receivedAt
            store(sub)
        case "subagent_finished":
            guard let id = Self.string(update["subagent_id"]) ?? Self.string(update["child_session_id"]) else { return }
            var sub = subagent(id: id, receivedAt: receivedAt)
            sub.finishedStatus = Self.string(update["status"]) ?? "completed"
            sub.durationMs = Self.int(update["duration_ms"]) ?? sub.durationMs
            sub.tokensUsed = Self.int(update["tokens_used"]) ?? sub.tokensUsed
            sub.compactingSince = nil
            store(sub)
        case "model_changed":
            model = Self.string(update["model_id"]) ?? model
            effort = Self.string(update["reasoning_effort"]) ?? effort
        case "goal_updated":
            let status = Self.string(update["status"]) ?? "active"
            guard status != "cleared" else { goal = nil; return }
            guard let objective = Self.string(update["objective"]) ?? goal?.objective else { return }
            goal = Goal(
                id: Self.string(update["goal_id"]) ?? goal?.id ?? "goal",
                objective: objective,
                status: status,
                phase: Self.string(update["phase"]) ?? goal?.phase ?? "idle",
                tokensUsed: Self.int(update["tokens_used"]) ?? goal?.tokensUsed ?? 0,
                tokenBudget: Self.int(update["token_budget"]) ?? goal?.tokenBudget,
                elapsedMs: Self.int(update["elapsed_ms"]) ?? goal?.elapsedMs ?? 0,
                rounds: Self.int(update["total_worker_rounds"]) ?? goal?.rounds ?? 0
            )
        case "scheduled_task_created", "scheduled_task_fired":
            guard let id = Self.string(update["task_id"]) else { return }
            let index = scheduledTasks.firstIndex(where: { $0.id == id })
            var task = index.map { scheduledTasks[$0] }
                ?? ScheduledTask(id: id, prompt: "", humanSchedule: nil, lastFiredAt: nil)
            task.prompt = Self.string(update["prompt"]) ?? task.prompt
            task.humanSchedule = Self.string(update["human_schedule"]) ?? task.humanSchedule
            if kind == "scheduled_task_fired" { task.lastFiredAt = receivedAt }
            if let index {
                scheduledTasks[index] = task
            } else {
                scheduledTasks.append(task)
                if scheduledTasks.count > Self.maxScheduledTasks { scheduledTasks.removeFirst() }
            }
        case "scheduled_task_deleted":
            guard let id = Self.string(update["task_id"]) else { return }
            scheduledTasks.removeAll(where: { $0.id == id })
        default:
            break
        }
    }

    /// Distill-advertised slash command (`available_commands_update`).
    public struct AdvertisedCommand: Equatable, Sendable {
        public var name: String
        public var description: String?
        public var hint: String?

        /// Composer subtitle: "<description> · <hint>".
        public var subtitle: String? {
            let parts = [description, hint].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    /// Replace-all list from an `available_commands_update` runtime event; nil for other methods.
    public static func advertisedCommands(method: String, payloadJSON: String) -> [AdvertisedCommand]? {
        guard method == "available_commands_update",
              let data = payloadJSON.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let raw = (payload["availableCommands"] as? [[String: Any]])
            ?? ((payload["update"] as? [String: Any])?["availableCommands"] as? [[String: Any]])
            ?? []
        return raw.compactMap { entry in
            guard let name = Self.string(entry["name"]) else { return nil }
            return AdvertisedCommand(
                name: name,
                description: Self.string(entry["description"]),
                hint: Self.string((entry["input"] as? [String: Any])?["hint"])
            )
        }
    }

    private mutating func setCompacting(sessionId: String?, since: Date?) {
        if let sessionId,
           let index = subagents.firstIndex(where: { $0.childSessionId == sessionId }) {
            subagents[index].compactingSince = since
        } else {
            mainCompactingSince = since
        }
    }

    private func subagent(id: String, receivedAt: Date) -> Subagent {
        subagents.first(where: { $0.id == id }) ?? Subagent(
            id: id,
            childSessionId: nil,
            type: "agent",
            description: "",
            model: nil,
            effort: nil,
            tokensUsed: 0,
            durationMs: 0,
            receivedAt: receivedAt,
            compactingSince: nil,
            finishedStatus: nil
        )
    }

    private mutating func store(_ sub: Subagent) {
        if let index = subagents.firstIndex(where: { $0.id == sub.id }) {
            subagents[index] = sub
        } else {
            subagents.append(sub)
            if subagents.count > Self.maxSubagents { subagents.removeFirst() }
        }
    }

    private static func string(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double, d.isFinite { return Int(d) }
        return nil
    }
}
