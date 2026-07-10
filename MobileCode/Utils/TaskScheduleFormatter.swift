//
//  TaskScheduleFormatter.swift
//  CodeAgentsMobile
//
//  Purpose: Format scheduled tasks for display
//

import Foundation

enum TaskScheduleFormatter {
    static func summary(for task: AgentScheduledTask, calendar: Calendar = .current) -> String {
        var calendar = calendar
        calendar.timeZone = TimeZone(identifier: task.timeZoneId) ?? calendar.timeZone

        let timeString = timeDescription(minutes: task.timeOfDayMinutes,
                                          timeZoneId: task.timeZoneId,
                                          calendar: calendar)
        let base: String

        let withTime: String
        switch task.frequency {
        case .once:
            let dateString = onceDateDescription(for: task, calendar: calendar)
            withTime = "Once on \(dateString) at \(timeString)"
            if let zoneLabel = timezoneLabelIfNonLocal(task.timeZoneId) {
                return "\(withTime) (\(zoneLabel))"
            }
            return withTime
        case .minutely:
            base = task.interval == 1 ? "Every minute" : "Every \(task.interval) minutes"
            return base
        case .hourly:
            base = task.interval == 1 ? "Hourly" : "Every \(task.interval) hours"
            return base
        case .daily:
            base = task.interval == 1 ? "Daily" : "Every \(task.interval) days"
            withTime = "\(base) at \(timeString)"
        case .weekly:
            base = task.interval == 1 ? "Weekly" : "Every \(task.interval) weeks"
            let days = weekdayList(mask: task.weekdayMask, calendar: calendar)
            withTime = "\(base) on \(days) at \(timeString)"
        case .monthly:
            base = task.interval == 1 ? "Monthly" : "Every \(task.interval) months"
            let detail = monthlyDetail(for: task, calendar: calendar)
            withTime = "\(base) \(detail) at \(timeString)"
        case .yearly:
            base = task.interval == 1 ? "Yearly" : "Every \(task.interval) years"
            let detail = yearlyDetail(for: task, calendar: calendar)
            withTime = "\(base) \(detail) at \(timeString)"
        }

        if let zoneLabel = timezoneLabelIfNonLocal(task.timeZoneId) {
            return "\(withTime) (\(zoneLabel))"
        }
        return withTime
    }

    static func promptPreview(_ prompt: String) -> String {
        let parsed = ComposedPromptParser.parse(prompt)
        let primary = parsed.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine = primary.split(separator: "\n").first, !firstLine.isEmpty {
            return String(firstLine)
        }

        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fallback = trimmed.split(separator: "\n").first, !fallback.isEmpty {
            return String(fallback)
        }
        return ""
    }

    /// Secondary line for Regular Tasks: next fire in the device's local clock, plus task timezone when it differs.
    static func nextRunDescription(for task: AgentScheduledTask, now: Date = Date()) -> String? {
        guard let nextRunAt = task.nextRunAt else { return nil }

        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = .current

        var line = "Next \(formatter.string(from: nextRunAt))"
        if let zoneLabel = timezoneLabelIfNonLocal(task.timeZoneId) {
            line += " · \(zoneLabel)"
        }
        if nextRunAt < now, task.isEnabled {
            line += " (overdue)"
        }
        return line
    }

    static func timezoneLabelIfNonLocal(_ timeZoneId: String) -> String? {
        let trimmed = timeZoneId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == TimeZone.current.identifier {
            return nil
        }
        if let zone = TimeZone(identifier: trimmed) {
            let seconds = zone.secondsFromGMT()
            if seconds == TimeZone.current.secondsFromGMT(),
               zone.isDaylightSavingTime() == TimeZone.current.isDaylightSavingTime() {
                // Same offset as device (e.g. Europe/Berlin vs Europe/Prague) — still show id when not identical.
            }
            return trimmed
        }
        return trimmed
    }

    static func date(for minutes: Int, timeZoneId: String, calendar: Calendar = .current) -> Date {
        var calendar = calendar
        calendar.timeZone = TimeZone(identifier: timeZoneId) ?? calendar.timeZone
        let hour = minutes / 60
        let minute = minutes % 60
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    static func minutes(from date: Date, timeZoneId: String, calendar: Calendar = .current) -> Int {
        var calendar = calendar
        calendar.timeZone = TimeZone(identifier: timeZoneId) ?? calendar.timeZone
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        return max(0, min(hour * 60 + minute, 1_439))
    }

    private static func timeDescription(minutes: Int, timeZoneId: String, calendar: Calendar) -> String {
        let time = date(for: minutes, timeZoneId: timeZoneId, calendar: calendar)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: time)
    }

    /// Date label for one-shot tasks (prefers nextRunAt, else month/day in task zone).
    private static func onceDateDescription(for task: AgentScheduledTask, calendar: Calendar) -> String {
        let fireDate: Date
        if let nextRunAt = task.nextRunAt {
            fireDate = nextRunAt
        } else {
            var components = DateComponents()
            components.year = calendar.component(.year, from: Date())
            components.month = task.monthOfYear
            components.day = min(task.dayOfMonth, 28)
            components.hour = task.timeOfDayMinutes / 60
            components.minute = task.timeOfDayMinutes % 60
            fireDate = calendar.date(from: components) ?? Date()
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: fireDate)
    }

    private static func weekdayList(mask: Int, calendar: Calendar) -> String {
        let selected = WeekdayMask.selected(in: mask, calendar: calendar)
        guard !selected.isEmpty else { return "No days" }
        let symbols = calendar.shortWeekdaySymbols
        let names = selected.map { symbols[$0.rawValue - 1] }
        return names.joined(separator: ", ")
    }

    private static func monthlyDetail(for task: AgentScheduledTask, calendar: Calendar) -> String {
        switch task.monthlyMode {
        case .dayOfMonth:
            return "on day \(task.dayOfMonth)"
        case .ordinalWeekday:
            let ordinal = task.ordinalWeek.displayName.lowercased()
            let weekdayName = calendar.weekdaySymbols[task.ordinalWeekday.rawValue - 1]
            return "on the \(ordinal) \(weekdayName)"
        }
    }

    private static func yearlyDetail(for task: AgentScheduledTask, calendar: Calendar) -> String {
        let monthName = monthName(for: task.monthOfYear, calendar: calendar)
        switch task.monthlyMode {
        case .dayOfMonth:
            return "on \(monthName) \(task.dayOfMonth)"
        case .ordinalWeekday:
            let ordinal = task.ordinalWeek.displayName.lowercased()
            let weekdayName = calendar.weekdaySymbols[task.ordinalWeekday.rawValue - 1]
            return "on the \(ordinal) \(weekdayName) of \(monthName)"
        }
    }

    private static func monthName(for month: Int, calendar: Calendar) -> String {
        let index = max(1, min(month, 12)) - 1
        return calendar.monthSymbols[index]
    }
}
