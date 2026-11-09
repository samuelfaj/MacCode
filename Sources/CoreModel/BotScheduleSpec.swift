import Foundation

/// Agent App schedule routing + frequency for a Bot routine.
/// Encoded on `bot_routine_definitions.schedule_spec_json`.
public struct BotScheduleSpec: Codable, Sendable, Equatable {
    public var provider: AgentProvider
    public var providerInstanceID: String
    public var model: String
    public var reasoningEffort: AgentReasoningEffort
    public var reasoningModel: String?
    public var distillMainEffortSelection: AgentEffortSelection?
    public var distillReasoningEffortSelection: AgentEffortSelection?
    public var routingMode: AgentRoutingMode
    /// Optional so specs saved before these options decode unchanged.
    public var distillExecutionMode: DistillExecutionMode?
    public var permissionMode: AgentPermissionMode?
    public var executionDestination: BotExecutionDestination?
    /// Nil means 1. Max runs of this routine active at once (1...5).
    public var maxConcurrentRuns: Int?

    /// Nil and out-of-range values resolve to the 1...5 limit.
    public var effectiveMaxConcurrentRuns: Int { min(max(maxConcurrentRuns ?? 1, 1), 5) }
    public var frequency: ScheduledTaskFrequency
    public var scheduledDate: Date
    public var intervalHours: Int
    public var localTimeHour: Int
    public var localTimeMinute: Int
    public var weekdays: [ScheduledWeekday]
    public var monthlyDay: Int
    public var timeZoneIdentifier: String
    /// Frequencies after the first; the flat fields above are rule 1 (JSON back-compat).
    public var additionalFrequencies: [ScheduledFrequencyRule]?

    private enum CodingKeys: String, CodingKey {
        case provider, providerInstanceID, model, reasoningEffort, reasoningModel
        case distillMainEffortSelection, distillReasoningEffortSelection, routingMode
        case distillExecutionMode = "distillUltracode"
        case permissionMode, executionDestination, maxConcurrentRuns, frequency, scheduledDate, intervalHours
        case localTimeHour, localTimeMinute, weekdays, monthlyDay, timeZoneIdentifier, additionalFrequencies
    }

    public init(
        provider: AgentProvider = .defaultProvider,
        providerInstanceID: String = AgentProvider.defaultProvider.rawValue,
        model: String = "",
        reasoningEffort: AgentReasoningEffort = .medium,
        reasoningModel: String? = nil,
        distillMainEffortSelection: AgentEffortSelection? = nil,
        distillReasoningEffortSelection: AgentEffortSelection? = nil,
        routingMode: AgentRoutingMode = .auto,
        frequency: ScheduledTaskFrequency = .daily,
        scheduledDate: Date = Date().addingTimeInterval(60 * 60),
        intervalHours: Int = 1,
        localTime: Date = Date(),
        weekdays: Set<ScheduledWeekday> = [.monday],
        monthlyDay: Int = 1,
        timeZoneIdentifier: String = TimeZone.current.identifier
    ) {
        self.provider = provider
        self.providerInstanceID = providerInstanceID
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.reasoningModel = reasoningModel
        self.distillMainEffortSelection = distillMainEffortSelection
        self.distillReasoningEffortSelection = distillReasoningEffortSelection
        self.routingMode = provider == .distill ? .manual : routingMode
        self.frequency = frequency
        self.scheduledDate = scheduledDate
        self.intervalHours = intervalHours
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let parts = calendar.dateComponents([.hour, .minute], from: localTime)
        self.localTimeHour = parts.hour ?? 9
        self.localTimeMinute = parts.minute ?? 0
        self.weekdays = weekdays.sorted()
        self.monthlyDay = monthlyDay
        self.timeZoneIdentifier = timeZoneIdentifier
        migrateLegacyProvider()
    }

    /// RemoteCode runs Distill only: a saved Codex/Claude/Grok route becomes Distill defaults.
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

    public var weekdaySet: Set<ScheduledWeekday> {
        get { Set(weekdays) }
        set { weekdays = newValue.sorted() }
    }

    public var localTime: Date {
        get {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
            return calendar.date(bySettingHour: localTimeHour, minute: localTimeMinute, second: 0, of: Date()) ?? Date()
        }
        set {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
            let parts = calendar.dateComponents([.hour, .minute], from: newValue)
            localTimeHour = parts.hour ?? 9
            localTimeMinute = parts.minute ?? 0
        }
    }

    /// All frequencies; rule 1 is stored in the flat fields.
    public var frequencyRules: [ScheduledFrequencyRule] {
        get {
            let first = ScheduledFrequencyRule(
                frequency: frequency,
                scheduledDate: scheduledDate,
                intervalHours: intervalHours,
                localTimeHour: localTimeHour,
                localTimeMinute: localTimeMinute,
                weekdays: weekdays,
                monthlyDay: monthlyDay
            )
            return [first] + (additionalFrequencies ?? [])
        }
        set {
            guard let first = newValue.first else { return }
            frequency = first.frequency
            scheduledDate = first.scheduledDate
            intervalHours = first.intervalHours
            localTimeHour = first.localTimeHour
            localTimeMinute = first.localTimeMinute
            weekdays = first.weekdays
            monthlyDay = first.monthlyDay
            let rest = Array(newValue.dropFirst())
            additionalFrequencies = rest.isEmpty ? nil : rest
        }
    }

    public func makeRecurrence() throws -> ScheduledTaskRecurrence {
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw BotScheduleSpecError.invalid("Select a valid IANA time zone.")
        }
        do {
            return try ScheduledFrequencyRule.combinedRecurrence(frequencyRules)
        } catch let error as ScheduledFrequencyRuleError {
            throw BotScheduleSpecError.invalid(error.message)
        }
    }

    public func displayNote() -> String {
        frequencyRules.map { $0.displayNote() }.joined(separator: ", ")
    }

    /// The first scheduled slot strictly after `date`, or nil for an invalid spec or a spent one-time schedule.
    public func nextOccurrence(after date: Date) -> Date? {
        guard let recurrence = try? makeRecurrence(),
              let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        return ScheduledTaskOccurrenceCalculator.nextOccurrence(
            after: date,
            recurrence: recurrence,
            timeZone: timeZone,
            calendar: Calendar(identifier: .gregorian)
        )
    }

    // PERF: JSONEncoder/Decoder with iso8601 strategy are expensive. Share one pair behind lock.
    private static let codecLock = NSLock()
    private static let sharedEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let sharedDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func encodedJSON() -> String {
        var normalized = self
        normalized.migrateLegacyProvider()
        if normalized.provider == .distill { normalized.routingMode = .manual }
        Self.codecLock.lock()
        let data = try? Self.sharedEncoder.encode(normalized)
        Self.codecLock.unlock()
        guard let data, let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    public static func decodeJSON(_ raw: String) -> BotScheduleSpec? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        Self.codecLock.lock()
        var decoded = try? Self.sharedDecoder.decode(BotScheduleSpec.self, from: data)
        Self.codecLock.unlock()
        decoded?.migrateLegacyProvider()
        if decoded?.provider == .distill { decoded?.routingMode = .manual }
        return decoded
    }

    /// JSON wins. Otherwise recover Frequency + local time from `displayNote()`
    /// (and the unpadded `Weekdays 9:00` bots persist via When).
    public static func resolved(json: String, note: String) -> BotScheduleSpec {
        decodeJSON(json) ?? parseDisplayNote(note) ?? BotScheduleSpec()
    }

    public static func parseDisplayNote(_ raw: String) -> BotScheduleSpec? {
        let note = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return nil }
        if note.compare("Once", options: .caseInsensitive) == .orderedSame {
            return makeParsed(frequency: .once)
        }
        if let hours = parseEveryHours(note) {
            return makeParsed(frequency: .hourly, intervalHours: hours)
        }
        if let monthly = parseMonthlyDay(note) {
            return makeParsed(
                frequency: .monthly,
                hour: monthly.hour,
                minute: monthly.minute,
                monthlyDay: monthly.day
            )
        }
        if let named = parseNamedTime(note) {
            return makeParsed(frequency: named.frequency, hour: named.hour, minute: named.minute)
        }
        return nil
    }

    private static func makeParsed(
        frequency: ScheduledTaskFrequency,
        hour: Int = 9,
        minute: Int = 0,
        intervalHours: Int = 1,
        monthlyDay: Int = 1
    ) -> BotScheduleSpec {
        var spec = BotScheduleSpec()
        spec.frequency = frequency
        spec.localTimeHour = hour
        spec.localTimeMinute = minute
        spec.intervalHours = intervalHours
        spec.monthlyDay = monthlyDay
        return spec
    }

    private static func parseNamedTime(
        _ note: String
    ) -> (frequency: ScheduledTaskFrequency, hour: Int, minute: Int)? {
        let pairs: [(String, ScheduledTaskFrequency)] = [
            ("Daily ", .daily),
            ("Weekdays ", .weekdays),
            ("Weekly ", .weekly),
        ]
        for (prefix, frequency) in pairs {
            guard let clock = suffix(note, after: prefix), let time = parseClock(clock) else { continue }
            return (frequency, time.hour, time.minute)
        }
        return nil
    }

    private static func parseEveryHours(_ note: String) -> Int? {
        guard let rest = suffix(note, after: "Every "), rest.hasSuffix("h") else { return nil }
        guard let hours = Int(rest.dropLast()), (1...24).contains(hours) else { return nil }
        return hours
    }

    private static func parseMonthlyDay(_ note: String) -> (day: Int, hour: Int, minute: Int)? {
        guard let rest = suffix(note, after: "Monthly day ") else { return nil }
        let tokens = rest.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count == 2,
              let day = Int(tokens[0]), (1...28).contains(day),
              let time = parseClock(String(tokens[1])) else { return nil }
        return (day, time.hour, time.minute)
    }

    private static func parseClock(_ raw: String) -> (hour: Int, minute: Int)? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hour = Int(parts[0]), (0...23).contains(hour),
              let minute = Int(parts[1]), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    private static func suffix(_ note: String, after prefix: String) -> String? {
        guard note.count >= prefix.count,
              note.prefix(prefix.count).compare(prefix, options: .caseInsensitive) == .orderedSame
        else { return nil }
        return String(note.dropFirst(prefix.count))
    }
}

public enum BotScheduleSpecError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case invalid(String)
    public var description: String {
        switch self {
        case .invalid(let message): return message
        }
    }
    public var errorDescription: String? { description }
}
