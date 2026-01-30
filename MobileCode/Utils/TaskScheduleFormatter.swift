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

        switch task.frequency {
        case .minutely:
            base = task.interval == 1 ? "Every minute" : "Every \(task.interval) minutes"
            return base
        case .hourly:
            base = task.interval == 1 ? "Hourly" : "Every \(task.interval) hours"
            return base
        case .daily:
            base = task.interval == 1 ? "Daily" : "Every \(task.interval) days"
            return "\(base) at \(timeString)"
        case .weekly:
            base = task.interval == 1 ? "Weekly" : "Every \(task.interval) weeks"
            let days = weekdayList(mask: task.weekdayMask, calendar: calendar)
            return "\(base) on \(days) at \(timeString)"
        case .monthly:
            base = task.interval == 1 ? "Monthly" : "Every \(task.interval) months"
            let detail = monthlyDetail(for: task, calendar: calendar)
            return "\(base) \(detail) at \(timeString)"
        case .yearly:
            base = task.interval == 1 ? "Yearly" : "Every \(task.interval) years"
            let detail = yearlyDetail(for: task, calendar: calendar)
            return "\(base) \(detail) at \(timeString)"
        }
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
