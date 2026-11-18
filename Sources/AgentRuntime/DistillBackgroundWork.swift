import Foundation
import CoreModel

/// Work a Distill session keeps running after the turn that started it ended,
/// as the session itself reports it.
///
/// WHY: Distill ends a turn while its background subagents, background tasks
/// and workflows keep running inside the same agent process, and it wakes the
/// agent on its own when they finish. Restarting that process kills the work
/// ("interrupted by process restart"), so the host has to know it is running.
struct DistillBackgroundWork: Sendable {
    /// Distill's agent-initiated turn families (`PromptOrigin::from_prompt_id`).
    static let agentTurnPromptPrefixes = [
        "task-completed-", "subagent-completed-", "workflow-completed-",
        "parent-agent-message-", "parent-message-", "notifications-",
        "goal-summary-", "goal-classifier-nudge-", "scheduler-fired-", "plan-resume-",
    ]
    /// Completed agent turns remembered so a stale `_meta.promptId` cannot reopen them.
    static let completedAgentTurnMemory = 64

    private var subagents: [String: String] = [:]
    private var tasks: [String: String] = [:]
    private var workflows: [String: String] = [:]
    /// Agent-initiated turns Distill started and has not finished yet.
    private(set) var agentTurns: Set<String> = []
    private var completedAgentTurns: [String] = []
    /// Last report about any of the above.
    private(set) var lastReportAt: Date?

    var isEmpty: Bool {
        subagents.isEmpty && tasks.isEmpty && workflows.isEmpty && agentTurns.isEmpty
    }

    var reportedTasks: [AgentBackgroundTask] {
        (tasks.map { AgentBackgroundTask(id: $0.key, kind: .unknown, description: $0.value) }
            + workflows.map { AgentBackgroundTask(id: $0.key, kind: .unknown, description: $0.value) }
            + subagents.map { AgentBackgroundTask(id: $0.key, kind: .agent, description: $0.value) })
            .sorted { $0.id < $1.id }
    }

    static func isAgentTurnPromptID(_ promptId: String) -> Bool {
        agentTurnPromptPrefixes.contains { promptId.hasPrefix($0) }
    }

    func isRunning(subagent id: String) -> Bool {
        subagents[id.lowercased()] != nil
    }

    /// Running work, or a report recent enough that the wake turn Distill starts
    /// right after a finish may not have announced itself yet.
    func isBusy(now: Date, quietPeriod: TimeInterval) -> Bool {
        if !isEmpty { return true }
        guard let lastReportAt else { return false }
        return now.timeIntervalSince(lastReportAt) < quietPeriod
    }

    /// Folds one `session/update` or `x.ai/session_notification` update.
    /// A replayed or load-time update (`live == false`) can only retire work:
    /// a new process never inherits the work its predecessor was running.
    /// Runs for every streamed chunk, so an ordinary update costs one switch.
    mutating func apply(update: [String: Any], promptId: String?, live: Bool, at now: Date) {
        let kind = update["sessionUpdate"] as? String
        var reported = true
        var turnChanged = false
        switch kind {
        case "subagent_spawned", "subagent_progress":
            if live, let id = Self.subagentID(update) { subagents[id] = Self.label(update["description"]) ?? subagents[id] ?? "" }
        case "subagent_finished":
            if let id = Self.subagentID(update) { subagents[id] = nil }
        case "task_backgrounded":
            if live, let id = Self.string(update["task_id"]) { tasks[id] = Self.taskLabel(update) ?? tasks[id] ?? "" }
        case "task_completed":
            let snapshot = update["task_snapshot"] as? [String: Any]
            if let id = Self.string(snapshot?["task_id"]) ?? Self.string(update["task_id"]) {
                tasks[id] = nil
            }
        case "background_tasks":
            var running: [String: String] = [:]
            for row in update["tasks"] as? [[String: Any]] ?? [] {
                guard let id = Self.string(row["task_id"]), live || tasks[id] != nil else { continue }
                running[id] = (live ? Self.taskLabel(row) : nil) ?? tasks[id] ?? ""
            }
            tasks = running
        case "workflow_updated":
            // Only an `active` workflow runs; paused and terminal ones do not.
            if let id = Self.string(update["run_id"]) {
                if Self.string(update["status"]) != "active" {
                    workflows[id] = nil
                } else if live {
                    workflows[id] = Self.label(update["objective"]) ?? Self.label(update["name"]) ?? workflows[id] ?? ""
                }
            }
        case "turn_completed":
            reported = false
            if let id = Self.string(update["prompt_id"]), Self.isAgentTurnPromptID(id) {
                turnChanged = agentTurns.remove(id) != nil
                if !completedAgentTurns.contains(id) {
                    completedAgentTurns.append(id)
                    if completedAgentTurns.count > Self.completedAgentTurnMemory {
                        completedAgentTurns.removeFirst(completedAgentTurns.count - Self.completedAgentTurnMemory)
                    }
                }
            }
        default:
            reported = false
            // Distill stamps every update with the prompt it runs; its own turns
            // use a family prefix, so a user prompt id fails on the first bytes.
            if live, let promptId, Self.isAgentTurnPromptID(promptId) {
                let id = promptId.lowercased()
                if !completedAgentTurns.contains(id) {
                    turnChanged = agentTurns.insert(id).inserted
                }
            }
        }
        if live, reported || turnChanged {
            lastReportAt = now
        }
    }

    private static func label(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(1024))
    }

    private static func taskLabel(_ row: [String: Any]) -> String? {
        label(row["description"]) ?? label(row["command"])
    }

    private static func subagentID(_ update: [String: Any]) -> String? {
        string(update["child_session_id"]) ?? string(update["subagent_id"])
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text.lowercased()
    }
}
