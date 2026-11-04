import Foundation

public enum ScheduledTaskRunStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case completed
    case failed
    case cancelled
    case skipped
}

public enum ScheduledTaskRunTrigger: String, Codable, Sendable, CaseIterable {
    case scheduled
    case catchUp
    case manual
}

public struct ScheduledTask: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public var prompt: String
    public var workspaceID: WorkspaceID
    public var workspacePathSnapshot: String
    public var runAsUser: String
    public var runAsUID: UInt32
    public var provider: AgentProvider
    public var providerInstanceID: String
    public var model: String
    public var reasoningEffort: AgentReasoningEffort
    public var reasoningModel: String?
    public var distillMainEffortSelection: AgentEffortSelection?
    public var distillReasoningEffortSelection: AgentEffortSelection?
    /// Optional for backward-compatible Codable decoding of tasks serialized
    /// before scheduled Auto routing existed. Missing values mean Manual.
    public var routingMode: AgentRoutingMode?
    /// Same run options a new Agent App message carries.
    public var distillExecutionMode: DistillExecutionMode
    public var permissionMode: AgentPermissionMode
    public var interactionMode: AgentInteractionMode
    public var executionMode: AgentExecutionMode
    /// Required when `executionMode` is `.worktree`.
    public var baseBranch: String?
    /// Max runs of this task allowed active at once (1...5). A due slot at the limit is skipped.
    public var maxConcurrentRuns: Int
    public var recurrence: ScheduledTaskRecurrence
    public var timeZoneIdentifier: String
    public var isEnabled: Bool
    public var nextRunAt: Date?
    public var lastRunAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        prompt: String,
        workspaceID: WorkspaceID,
        workspacePathSnapshot: String,
        runAsUser: String,
        runAsUID: UInt32,
        provider: AgentProvider,
        providerInstanceID: String,
        model: String,
        reasoningEffort: AgentReasoningEffort,
        reasoningModel: String? = nil,
        distillMainEffortSelection: AgentEffortSelection? = nil,
        distillReasoningEffortSelection: AgentEffortSelection? = nil,
        routingMode: AgentRoutingMode = .manual,
        distillExecutionMode: DistillExecutionMode = .auto,
        permissionMode: AgentPermissionMode = .fullAccess,
        interactionMode: AgentInteractionMode = .default,
        executionMode: AgentExecutionMode = .local,
        baseBranch: String? = nil,
        maxConcurrentRuns: Int = 1,
        recurrence: ScheduledTaskRecurrence,
        timeZoneIdentifier: String,
        isEnabled: Bool = true,
        nextRunAt: Date? = nil,
        lastRunAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.workspaceID = workspaceID
        self.workspacePathSnapshot = workspacePathSnapshot
        self.runAsUser = runAsUser
        self.runAsUID = runAsUID
        self.provider = provider
        self.providerInstanceID = providerInstanceID
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.reasoningModel = reasoningModel
        self.distillMainEffortSelection = distillMainEffortSelection
        self.distillReasoningEffortSelection = distillReasoningEffortSelection
        self.routingMode = routingMode
        self.distillExecutionMode = distillExecutionMode
        self.permissionMode = permissionMode
        self.interactionMode = interactionMode
        self.executionMode = executionMode
        self.baseBranch = baseBranch
        self.maxConcurrentRuns = maxConcurrentRuns
        self.recurrence = recurrence
        self.timeZoneIdentifier = timeZoneIdentifier
        self.isEnabled = isEnabled
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        migrateLegacyProvider()
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, prompt, workspaceID, workspacePathSnapshot, runAsUser, runAsUID
        case provider, providerInstanceID, model, reasoningEffort, reasoningModel
        case distillMainEffortSelection, distillReasoningEffortSelection, routingMode
        case permissionMode, interactionMode, executionMode, baseBranch, maxConcurrentRuns
        case distillExecutionMode = "distillUltracode"
        case recurrence, timeZoneIdentifier, isEnabled, nextRunAt, lastRunAt, createdAt, updatedAt
    }

    /// Tasks serialized before the run options existed keep the old run: Full Access, Local, no Ultracode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        prompt = try c.decode(String.self, forKey: .prompt)
        workspaceID = try c.decode(WorkspaceID.self, forKey: .workspaceID)
        workspacePathSnapshot = try c.decode(String.self, forKey: .workspacePathSnapshot)
        runAsUser = try c.decode(String.self, forKey: .runAsUser)
        runAsUID = try c.decode(UInt32.self, forKey: .runAsUID)
        provider = try c.decode(AgentProvider.self, forKey: .provider)
        providerInstanceID = try c.decode(String.self, forKey: .providerInstanceID)
        model = try c.decode(String.self, forKey: .model)
        reasoningEffort = try c.decode(AgentReasoningEffort.self, forKey: .reasoningEffort)
        reasoningModel = try c.decodeIfPresent(String.self, forKey: .reasoningModel)
        distillMainEffortSelection = try c.decodeIfPresent(AgentEffortSelection.self, forKey: .distillMainEffortSelection)
        distillReasoningEffortSelection = try c.decodeIfPresent(AgentEffortSelection.self, forKey: .distillReasoningEffortSelection)
        routingMode = try c.decodeIfPresent(AgentRoutingMode.self, forKey: .routingMode)
        distillExecutionMode = try c.decodeIfPresent(DistillExecutionMode.self, forKey: .distillExecutionMode) ?? .auto
        permissionMode = try c.decodeIfPresent(AgentPermissionMode.self, forKey: .permissionMode) ?? .fullAccess
        interactionMode = try c.decodeIfPresent(AgentInteractionMode.self, forKey: .interactionMode) ?? .default
        executionMode = try c.decodeIfPresent(AgentExecutionMode.self, forKey: .executionMode) ?? .local
        baseBranch = try c.decodeIfPresent(String.self, forKey: .baseBranch)
        maxConcurrentRuns = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentRuns) ?? 1
        recurrence = try c.decode(ScheduledTaskRecurrence.self, forKey: .recurrence)
        timeZoneIdentifier = try c.decode(String.self, forKey: .timeZoneIdentifier)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        nextRunAt = try c.decodeIfPresent(Date.self, forKey: .nextRunAt)
        lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    /// RemoteCode runs Distill only: a saved Codex/Claude/Grok route becomes Distill defaults.
    /// Prompt and schedule are kept; the model is resolved from the Distill catalog at run start.
    public mutating func migrateLegacyProvider() {
        guard !provider.isSelectable else { return }
        provider = .distill
        providerInstanceID = AgentProvider.distill.rawValue
        model = ""
        reasoningEffort = .medium
        reasoningModel = nil
        distillMainEffortSelection = nil
        distillReasoningEffortSelection = nil
        routingMode = .manual
    }

    public var effectiveRoutingMode: AgentRoutingMode {
        provider == .distill ? .manual : (routingMode ?? .manual)
    }

    public func validationErrors() -> [String] {
        var errors: [String] = []
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty { errors.append("Title is required.") }
        if trimmedTitle.count > 120 { errors.append("Title must be at most 120 characters.") }
        if trimmedPrompt.isEmpty { errors.append("Prompt is required.") }
        if trimmedPrompt.utf8.count > 65_536 { errors.append("Prompt must be at most 64 KiB.") }
        if workspacePathSnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("Workspace path is required.") }
        if runAsUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("System user is required.") }
        if runAsUID < 500 || runAsUID == UInt32.max { errors.append("System user must be an eligible non-root account.") }
        // Provider/Source is always user-chosen (Agent App parity). Auto only
        // selects the model within that host — never the provider itself.
        if providerInstanceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Provider is required.")
        }
        if effectiveRoutingMode == .manual,
           model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Model is required.")
        }
        if executionMode == .worktree,
           (baseBranch ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Worktree runs need a base branch.")
        }
        if TimeZone(identifier: timeZoneIdentifier) == nil { errors.append("Time zone must be a valid IANA identifier.") }
        if case .multiple(let rules) = recurrence {
            if rules.count > ScheduledTaskRecurrence.maxRules { errors.append("At most 24 frequencies.") }
            let hasNested = rules.contains { if case .multiple = $0 { return true } else { return false } }
            if hasNested || Set(rules).count != rules.count { errors.append("Frequencies must be unique.") }
        }
        for rule in recurrence.rules {
            switch rule {
            case .hourly(_, let interval) where !ScheduledTaskRecurrence.isValidHourlyInterval(interval):
                errors.append("Hourly interval must be between 1 and 24.")
            case .weekly(let days, _) where !ScheduledTaskRecurrence.isValidWeeklyDays(days):
                errors.append("Weekly schedules require unique weekdays.")
            case .monthly(let day, _) where !ScheduledTaskRecurrence.isValidMonthlyDay(day):
                errors.append("Monthly day must be between 1 and 28.")
            default:
                break
            }
        }
        return errors
    }

    public func calculatedNextRun(after date: Date) -> Date? {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        return ScheduledTaskOccurrenceCalculator.nextOccurrence(
            after: date,
            recurrence: recurrence,
            timeZone: timeZone,
            calendar: Calendar(identifier: .gregorian)
        )
    }

    /// Next pointer after a claimed/spent occurrence (never re-selects that slot).
    public func calculatedNextRunAfterSpent(_ scheduledAt: Date) -> Date? {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        return ScheduledTaskOccurrenceCalculator.nextOccurrenceAfterSpent(
            scheduledAt: scheduledAt,
            recurrence: recurrence,
            timeZone: timeZone
        )
    }
}

public struct ScheduledTaskRun: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let taskID: UUID
    public let occurrenceKey: String
    public let trigger: ScheduledTaskRunTrigger
    public let scheduledAt: Date
    public let queuedAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var status: ScheduledTaskRunStatus
    public var threadID: AgentThreadID?
    public var agentRunID: AgentRunID?
    public var errorCode: String?
    public var errorSummary: String?
    public var leaseOwner: String?
    public var heartbeatAt: Date?

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        occurrenceKey: String,
        trigger: ScheduledTaskRunTrigger,
        scheduledAt: Date,
        queuedAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        status: ScheduledTaskRunStatus = .queued,
        threadID: AgentThreadID? = nil,
        agentRunID: AgentRunID? = nil,
        errorCode: String? = nil,
        errorSummary: String? = nil,
        leaseOwner: String? = nil,
        heartbeatAt: Date? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.occurrenceKey = occurrenceKey
        self.trigger = trigger
        self.scheduledAt = scheduledAt
        self.queuedAt = queuedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.threadID = threadID
        self.agentRunID = agentRunID
        self.errorCode = errorCode
        self.errorSummary = errorSummary
        self.leaseOwner = leaseOwner
        self.heartbeatAt = heartbeatAt
    }
}

public enum ScheduledTaskFrequency: String, Codable, Sendable, CaseIterable, Identifiable {
    case once
    case hourly
    case daily
    case weekdays
    case weekly
    case monthly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .once: return "Once"
        case .hourly: return "Hourly"
        case .daily: return "Daily"
        case .weekdays: return "Weekdays"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }
}
