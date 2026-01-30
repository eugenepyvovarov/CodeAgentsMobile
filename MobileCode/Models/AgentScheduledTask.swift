//
//  AgentScheduledTask.swift
//  CodeAgentsMobile
//
//  Purpose: Models for scheduled agent tasks
//

import Foundation
import SwiftData

enum TaskFrequency: String, Codable, CaseIterable {
    case minutely
    case hourly
    case daily
    case weekly
    case monthly
    case yearly

    var displayName: String {
        switch self {
        case .minutely:
            return "Minutes"
        case .hourly:
            return "Hours"
        case .daily:
            return "Daily"
        case .weekly:
            return "Weekly"
        case .monthly:
            return "Monthly"
        case .yearly:
            return "Yearly"
        }
    }

    var unitName: String {
        switch self {
        case .minutely:
            return "minute"
        case .hourly:
            return "hour"
        case .daily:
            return "day"
        case .weekly:
            return "week"
        case .monthly:
            return "month"
        case .yearly:
            return "year"
        }
    }
}

enum TaskMonthlyMode: String, Codable, CaseIterable {
    case dayOfMonth
    case ordinalWeekday

    var displayName: String {
        switch self {
        case .dayOfMonth:
            return "Day"
        case .ordinalWeekday:
            return "Weekday"
        }
    }
}

enum WeekdayOrdinal: String, Codable, CaseIterable {
    case first
    case second
    case third
    case fourth
    case last

    var displayName: String {
        switch self {
        case .first:
            return "First"
        case .second:
            return "Second"
        case .third:
            return "Third"
        case .fourth:
            return "Fourth"
        case .last:
            return "Last"
        }
    }
}

enum Weekday: Int, Codable, CaseIterable, Identifiable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    var id: Int { rawValue }

    static func current(in calendar: Calendar) -> Weekday {
        let weekdayValue = calendar.component(.weekday, from: Date())
        return Weekday(rawValue: weekdayValue) ?? .monday
    }

    static func ordered(using calendar: Calendar) -> [Weekday] {
        let all = Weekday.allCases
        let firstWeekday = calendar.firstWeekday
        guard let startIndex = all.firstIndex(where: { $0.rawValue == firstWeekday }) else {
            return all
        }
        return Array(all[startIndex...] + all[..<startIndex])
    }
}

enum WeekdayMask {
    static func mask(for weekday: Weekday) -> Int {
        1 << (weekday.rawValue - 1)
    }

    static func contains(_ mask: Int, weekday: Weekday) -> Bool {
        (mask & self.mask(for: weekday)) != 0
    }

    static func toggle(_ mask: Int, weekday: Weekday) -> Int {
        mask ^ self.mask(for: weekday)
    }

    static func selected(in mask: Int, calendar: Calendar) -> [Weekday] {
        Weekday.ordered(using: calendar).filter { contains(mask, weekday: $0) }
    }
}

@Model
final class AgentScheduledTask {
    var id: UUID
    var projectId: UUID
    var title: String
    var prompt: String
    var isEnabled: Bool
    var timeZoneId: String
    var frequency: TaskFrequency
    var interval: Int
    var weekdayMask: Int
    var monthlyMode: TaskMonthlyMode
    var dayOfMonth: Int
    var ordinalWeek: WeekdayOrdinal
    var ordinalWeekday: Weekday
    var monthOfYear: Int
    var timeOfDayMinutes: Int
    var nextRunAt: Date?
    var lastRunAt: Date?
    var remoteId: String?
    var createdAt: Date
    var updatedAt: Date

    init(projectId: UUID,
         title: String = "",
         prompt: String,
         isEnabled: Bool = true,
         timeZoneId: String = TimeZone.current.identifier,
         frequency: TaskFrequency = .daily,
         interval: Int = 1,
         weekdayMask: Int? = nil,
         monthlyMode: TaskMonthlyMode = .dayOfMonth,
         dayOfMonth: Int = Calendar.current.component(.day, from: Date()),
         ordinalWeek: WeekdayOrdinal = .first,
         ordinalWeekday: Weekday = Weekday.current(in: Calendar.current),
         monthOfYear: Int = Calendar.current.component(.month, from: Date()),
         timeOfDayMinutes: Int = AgentScheduledTask.defaultTimeOfDayMinutes(),
         nextRunAt: Date? = nil,
         lastRunAt: Date? = nil,
         remoteId: String? = nil,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = UUID()
        self.projectId = projectId
        self.title = title
        self.prompt = prompt
        self.isEnabled = isEnabled
        self.timeZoneId = timeZoneId
        self.frequency = frequency
        self.interval = max(1, interval)
        self.weekdayMask = weekdayMask ?? WeekdayMask.mask(for: Weekday.current(in: Calendar.current))
        self.monthlyMode = monthlyMode
        self.dayOfMonth = min(max(1, dayOfMonth), 31)
        self.ordinalWeek = ordinalWeek
        self.ordinalWeekday = ordinalWeekday
        self.monthOfYear = min(max(1, monthOfYear), 12)
        self.timeOfDayMinutes = max(0, min(timeOfDayMinutes, 1_439))
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.remoteId = remoteId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func defaultTimeOfDayMinutes(calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: Date())
        let hour = components.hour ?? 9
        let minute = components.minute ?? 0
        return max(0, min(hour * 60 + minute, 1_439))
    }

    func markUpdated() {
        updatedAt = Date()
    }
}
