import Foundation

/// Work a Distill session keeps running after the turn that started it ended,
/// as the session itself reports it.
///
/// WHY: Distill ends a turn while its background subagents, background tasks
/// and workflows keep running inside the same agent process, and it wakes the
/// agent on its own when they finish. Restarting that process kills the work
/// ("interrupted by process restart"), so the host has to know it is running.
struct DistillBackgroundWork: Equatable, Sendable {
    /// Distill's agent-initiated turn families (`PromptOrigin::from_prompt_id`).
    static let agentTurnPromptPrefixes = [
        "task-completed-", "subagent-completed-", "workflow-completed-",
        "parent-agent-message-", "parent-message-", "notifications-",
        "goal-summary-", "goal-classifier-nudge-", "scheduler-fired-", "plan-resume-",
    ]
    /// Completed agent turns remembered so a stale `_meta.promptId` cannot reopen them.
    static let completedAgentTurnMemory = 64

    private(set) var subagents: Set<String> = []
    private(set) var tasks: Set<String> = []
    private(set) var workflows: Set<String> = []
    /// Agent-initiated turns Distill started and has not finished yet.
    private(set) var agentTurns: Set<String> = []
    private var completedAgentTurns: [String] = []
    /// Last report about any of the above.
    private(set) var lastReportAt: Date?

    var isEmpty: Bool {
        subagents.isEmpty && tasks.isEmpty && workflows.isEmpty && agentTurns.isEmpty
    }

    static func isAgentTurnPromptID(_ promptId: String) -> Bool {
        agentTurnPromptPrefixes.contains { promptId.hasPrefix($0) }
    }

    func isRunning(subagent id: String) -> Bool {
        subagents.contains(id.lowercased())
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
    mutating func apply(update: [String: Any], promptId: String?, live: Bool, at now: Date) {
        let before = self
        let kind = update["sessionUpdate"] as? String
        switch kind {
        case "subagent_spawned", "subagent_progress":
            if live, let id = Self.subagentID(update) { subagents.insert(id) }
        case "subagent_finished":
            if let id = Self.subagentID(update) { subagents.remove(id) }
        case "task_backgrounded":
            if live, let id = Self.string(update["task_id"]) { tasks.insert(id) }
        case "task_completed":
            let snapshot = update["task_snapshot"] as? [String: Any]
            if let id = Self.string(snapshot?["task_id"]) ?? Self.string(update["task_id"]) {
                tasks.remove(id)
            }
        case "background_tasks":
            let running = Set((update["tasks"] as? [[String: Any]] ?? []).compactMap { Self.string($0["task_id"]) })
            if live { tasks = running } else { tasks.formIntersection(running) }
        case "workflow_updated":
            // Only an `active` workflow runs; paused and terminal ones do not.
            if let id = Self.string(update["run_id"]) {
                if Self.string(update["status"]) != "active" {
                    workflows.remove(id)
                } else if live {
                    workflows.insert(id)
                }
            }
        case "turn_completed":
            if let id = Self.string(update["prompt_id"]), Self.isAgentTurnPromptID(id) {
                agentTurns.remove(id)
                if !completedAgentTurns.contains(id) {
                    completedAgentTurns.append(id)
                    if completedAgentTurns.count > Self.completedAgentTurnMemory {
                        completedAgentTurns.removeFirst(completedAgentTurns.count - Self.completedAgentTurnMemory)
                    }
                }
            }
        default:
            break
        }
        if live, kind != "turn_completed", let promptId = Self.string(promptId),
           Self.isAgentTurnPromptID(promptId), !completedAgentTurns.contains(promptId) {
            agentTurns.insert(promptId)
        }
        if live, self != before || Self.reportsBackgroundWork(kind) {
            lastReportAt = now
        }
    }

    private static func reportsBackgroundWork(_ kind: String?) -> Bool {
        switch kind {
        case "subagent_spawned", "subagent_progress", "subagent_finished",
             "task_backgrounded", "task_completed", "background_tasks", "workflow_updated":
            return true
        default:
            return false
        }
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
