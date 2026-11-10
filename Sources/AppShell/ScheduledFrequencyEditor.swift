import SwiftUI
import CoreModel
import DesignSystemKit

/// Frequency rows shared by the workspace Schedule Tasks and bot Schedule Tasks editors.
/// Mounted inside the parent's `editorGroup("Frequency")`.
struct ScheduledFrequencyEditor: View {
    @Binding var rules: [ScheduledFrequencyRule]
    @Binding var timeZoneIdentifier: String
    let identifierPrefix: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }

    var body: some View {
        ForEach(rules.indices, id: \.self) { index in
            if rules.count > 1 { ruleHeader(index) }
            ruleRows(index)
        }
        addRow
        formRow("Time zone") {
            Picker(L("Time zone"), selection: $timeZoneIdentifier) {
                ForEach(Self.commonTimeZones, id: \.self) {
                    Text($0.replacingOccurrences(of: "_", with: " ")).tag($0)
                }
                if !Self.commonTimeZones.contains(timeZoneIdentifier) {
                    Text(timeZoneIdentifier).tag(timeZoneIdentifier)
                }
            }
            .labelsHidden()
            .accessibilityIdentifier("\(identifierPrefix).timeZone")
        }
    }

    private func id(_ name: String, _ index: Int) -> String {
        index == 0 ? "\(identifierPrefix).\(name)" : "\(identifierPrefix).\(name).\(index + 1)"
    }

    /// Index-safe binding: a removed row may still evaluate its bindings once.
    private func ruleBinding(_ index: Int) -> Binding<ScheduledFrequencyRule> {
        Binding(
            get: { rules.indices.contains(index) ? rules[index] : ScheduledFrequencyRule() },
            set: { newValue in
                guard rules.indices.contains(index) else { return }
                rules[index] = newValue
            }
        )
    }

    private func animated(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2), change)
    }

    private func ruleHeader(_ index: Int) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            HStack {
                Text(L("Frequency %1$@", index + 1))
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                Spacer(minLength: DS.Space.lg)
                Button {
                    animated {
                        guard rules.indices.contains(index) else { return }
                        rules.remove(at: index)
                    }
                } label: {
                    Image(systemName: "minus.circle")
                        .frame(minWidth: 24, minHeight: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Remove frequency \(index + 1)")
                .accessibilityLabel("Remove frequency \(index + 1)")
                .accessibilityIdentifier("\(identifierPrefix).frequency.remove.\(index + 1)")
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)
        }
    }

    private var addRow: some View {
        VStack(spacing: 0) {
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            HStack {
                Button {
                    animated { rules.append(rules.last?.suggestedNext() ?? ScheduledFrequencyRule()) }
                } label: {
                    Label(L("Add frequency"), systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .foregroundColor(DS.Palette.accent)
                .disabled(rules.count >= ScheduledTaskRecurrence.maxRules)
                .help("Up to \(ScheduledTaskRecurrence.maxRules) frequencies")
                .accessibilityIdentifier("\(identifierPrefix).frequency.add")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)
        }
    }

    @ViewBuilder
    private func ruleRows(_ index: Int) -> some View {
        let rule = ruleBinding(index)
        formRow("Repeat") {
            Picker(L("Frequency"), selection: rule.frequency) {
                ForEach(ScheduledTaskFrequency.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .accessibilityIdentifier(id("frequency", index))
        }
        switch rule.wrappedValue.frequency {
        case .once:
            formRow("At") {
                DatePicker("Run at", selection: rule.scheduledDate)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }
        case .hourly:
            formRow("Interval") {
                Stepper("Every \(rule.wrappedValue.intervalHours)h", value: rule.intervalHours, in: 1...24)
                    .foregroundColor(DS.Palette.text)
            }
        case .daily, .weekdays:
            timeRow(rule)
        case .weekly:
            timeRow(rule)
            formRow("Days") {
                HStack(spacing: DS.Space.xs) {
                    ForEach(ScheduledWeekday.allCases, id: \.self) { day in
                        Toggle(dayLabel(day), isOn: Binding(
                            get: { rule.wrappedValue.weekdays.contains(day) },
                            set: { enabled in
                                var days = Set(rule.wrappedValue.weekdays)
                                if enabled { days.insert(day) } else { days.remove(day) }
                                rule.wrappedValue.weekdays = days.sorted()
                            }
                        ))
                        .toggleStyle(.button)
                        .font(DS.Font.caption.weight(.semibold))
                    }
                }
            }
        case .monthly:
            formRow("Day") {
                Stepper("Day \(rule.wrappedValue.monthlyDay)", value: rule.monthlyDay, in: 1...28)
                    .foregroundColor(DS.Palette.text)
            }
            timeRow(rule)
        }
    }

    private func timeRow(_ rule: Binding<ScheduledFrequencyRule>) -> some View {
        let tz = timeZone
        return formRow("At") {
            DatePicker("Local time", selection: Binding(
                get: { rule.wrappedValue.localTime(in: tz) },
                set: { rule.wrappedValue.setLocalTime($0, in: tz) }
            ), displayedComponents: .hourAndMinute)
                .labelsHidden()
                .environment(\.timeZone, tz)
        }
    }

    private func formRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        ScheduleEditorRow(label, control: content)
    }

    private func dayLabel(_ day: ScheduledWeekday) -> String {
        switch day {
        case .sunday: return "S"
        case .monday: return "M"
        case .tuesday: return "T"
        case .wednesday: return "W"
        case .thursday: return "T"
        case .friday: return "F"
        case .saturday: return "S"
        }
    }

    private static let commonTimeZones: [String] = {
        let preferred = [
            TimeZone.current.identifier,
            "UTC",
            "America/Asuncion",
            "America/New_York",
            "America/Los_Angeles",
            "America/Sao_Paulo",
            "Europe/London",
            "Europe/Berlin",
            "Asia/Tokyo"
        ]
        var seen = Set<String>()
        return preferred.filter { TimeZone(identifier: $0) != nil && seen.insert($0).inserted }
    }()
}
