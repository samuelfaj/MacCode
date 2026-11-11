import Foundation

public enum ScheduledFrequencyRuleError: Error, Equatable {
    case invalid(String)

    public var message: String {
        switch self {
        case .invalid(let message): return message
        }
    }
}

/// One editable frequency of a schedule. A task carries one or more of these
/// that combine into a single `ScheduledTaskRecurrence`.
public struct ScheduledFrequencyRule: Codable, Sendable, Equatable {
    public var frequency: ScheduledTaskFrequency
    /// Once instant / hourly anchor.
    public var scheduledDate: Date
    public var intervalHours: Int
    public var localTimeHour: Int
    public var localTimeMinute: Int
    public var weekdays: [ScheduledWeekday]
    public var monthlyDay: Int

    public init(
        frequency: ScheduledTaskFrequency = .daily,
        scheduledDate: Date = Date().addingTimeInterval(3600),
        intervalHours: Int = 1,
        localTimeHour: Int = 9,
        localTimeMinute: Int = 0,
        weekdays: [ScheduledWeekday] = [.monday],
        monthlyDay: Int = 1
    ) {
        self.frequency = frequency
        self.scheduledDate = scheduledDate
        self.intervalHours = intervalHours
        self.localTimeHour = localTimeHour
        self.localTimeMinute = localTimeMinute
        self.weekdays = weekdays.sorted()
        self.monthlyDay = monthlyDay
    }

    /// Maps a leaf recurrence; `.multiple` uses its first rule.
    public init(recurrence: ScheduledTaskRecurrence) {
        self.init()
        switch recurrence {
        case .once(let at):
            frequency = .once
            scheduledDate = at
        case .hourly(let anchor, let interval):
            frequency = .hourly
            scheduledDate = anchor
            intervalHours = interval
        case .daily(let time):
            frequency = .daily
            setTime(time)
        case .weekdays(let time):
            frequency = .weekdays
            setTime(time)
        case .weekly(let days, let time):
            frequency = .weekly
            weekdays = days.sorted()
            setTime(time)
        case .monthly(let day, let time):
            frequency = .monthly
            monthlyDay = day
            setTime(time)
        case .multiple(let rules):
            if let first = rules.first { self = ScheduledFrequencyRule(recurrence: first) }
        }
    }

    private mutating func setTime(_ time: ScheduledLocalTime) {
        localTimeHour = time.hour
        localTimeMinute = time.minute
    }

    public func makeRecurrence() throws -> ScheduledTaskRecurrence {
        guard let time = ScheduledLocalTime(hour: localTimeHour, minute: localTimeMinute) else {
            throw ScheduledFrequencyRuleError.invalid(L("Select a valid local time."))
        }
        switch frequency {
        case .once:
            return .once(at: ScheduledTaskOccurrenceCalculator.canonicalInstant(scheduledDate))
        case .hourly:
            guard let value = ScheduledTaskRecurrence.makeHourly(anchor: scheduledDate, intervalHours: intervalHours) else {
                throw ScheduledFrequencyRuleError.invalid(L("Hourly interval must be between 1 and 24."))
            }
            return value
        case .daily:
            return .daily(at: time)
        case .weekdays:
            return .weekdays(at: time)
        case .weekly:
            guard let value = ScheduledTaskRecurrence.makeWeekly(on: weekdays, at: time) else {
                throw ScheduledFrequencyRuleError.invalid(L("Select at least one weekday."))
            }
            return value
        case .monthly:
            guard let value = ScheduledTaskRecurrence.makeMonthly(day: monthlyDay, at: time) else {
                throw ScheduledFrequencyRuleError.invalid(L("Monthly day must be between 1 and 28."))
            }
            return value
        }
    }

    public static func combinedRecurrence(_ rules: [ScheduledFrequencyRule]) throws -> ScheduledTaskRecurrence {
        guard !rules.isEmpty else { throw ScheduledFrequencyRuleError.invalid(L("Add at least one frequency.")) }
        guard rules.count <= ScheduledTaskRecurrence.maxRules else {
            throw ScheduledFrequencyRuleError.invalid(L("At most %1$@ frequencies.", ScheduledTaskRecurrence.maxRules))
        }
        var recurrences: [ScheduledTaskRecurrence] = []
        for (index, rule) in rules.enumerated() {
            do {
                recurrences.append(try rule.makeRecurrence())
            } catch let error as ScheduledFrequencyRuleError {
                guard rules.count > 1 else { throw error }
                throw ScheduledFrequencyRuleError.invalid("Frequency \(index + 1): \(error.message)")
            }
        }
        guard let combined = ScheduledTaskRecurrence.combining(recurrences) else {
            throw ScheduledFrequencyRuleError.invalid(L("Add at least one frequency."))
        }
        return combined
    }

    /// Same repeat/days, one hour later, so "Add frequency" yields a distinct valid rule.
    public func suggestedNext() -> ScheduledFrequencyRule {
        var next = self
        next.localTimeHour = (localTimeHour + 1) % 24
        next.scheduledDate = scheduledDate.addingTimeInterval(3600)
        return next
    }

    public func localTime(in timeZone: TimeZone, reference: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(bySettingHour: localTimeHour, minute: localTimeMinute, second: 0, of: reference) ?? reference
    }

    public mutating func setLocalTime(_ date: Date, in timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        localTimeHour = parts.hour ?? 9
        localTimeMinute = parts.minute ?? 0
    }

    public func displayNote() -> String {
        // PERF: manual two-digit decimal avoids String(format:) ICU per schedule display.
        let hh = localTimeHour < 10 ? "0\(localTimeHour)" : "\(localTimeHour)"
        let mm = localTimeMinute < 10 ? "0\(localTimeMinute)" : "\(localTimeMinute)"
        let time = "\(hh):\(mm)"
        switch frequency {
        case .once:
            return "Once"
        case .hourly:
            return "Every \(intervalHours)h"
        case .daily:
            return "Daily \(time)"
        case .weekdays:
            return "Weekdays \(time)"
        case .weekly:
            return "Weekly \(time)"
        case .monthly:
            return L("Monthly day %1$@ %2$@", monthlyDay, time)
        }
    }
}
