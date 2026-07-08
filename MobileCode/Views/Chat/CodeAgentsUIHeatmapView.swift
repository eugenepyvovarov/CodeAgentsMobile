//
//  CodeAgentsUIHeatmapView.swift
//  CodeAgentsMobile
//
//  Purpose: Heatmap calendar widget for codeagents_ui chart blocks
//

import SwiftUI

struct CodeAgentsUIHeatmapView: View {
    let chart: CodeAgentsUIHeatmapChart

    private let cellSize: CGFloat = 12
    private let cellSpacing: CGFloat = 4
    private let labelColumnWidth: CGFloat = 28

    var body: some View {
        let layout = HeatmapLayout(chart: chart)
        if layout.weeks.isEmpty {
            Text("No heatmap data")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: cellSpacing) {
                        ForEach(0..<7, id: \.self) { index in
                            if let label = layout.weekdayLabels[index] {
                                Text(label)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .frame(height: cellSize, alignment: .leading)
                            } else {
                                Color.clear
                                    .frame(height: cellSize)
                            }
                        }
                    }
                    .frame(width: labelColumnWidth, alignment: .leading)
                    .padding(.top, 14)
                    .layoutPriority(0)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: cellSpacing) {
                            ForEach(Array(layout.weeks.enumerated()), id: \.offset) { index, week in
                                VStack(spacing: cellSpacing) {
                                    Text(layout.monthLabels[index])
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .frame(height: 12)
                                    VStack(spacing: cellSpacing) {
                                        ForEach(Array(week.enumerated()), id: \.offset) { dayIndex, date in
                                            HeatmapCell(
                                                color: layout.color(for: date),
                                                size: cellSize
                                            )
                                            .accessibilityLabel(layout.accessibilityLabel(for: date, row: dayIndex))
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                }

                if layout.showLegend {
                    HStack(spacing: 6) {
                        Text("Less")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        ForEach(Array(layout.palette.enumerated()), id: \.offset) { _, color in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(color)
                                .frame(width: cellSize, height: cellSize)
                        }
                        Text("More")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(.systemGray4).opacity(0.6), lineWidth: 0.5)
            )
        }
    }

    private struct HeatmapCell: View {
        let color: Color
        let size: CGFloat

        var body: some View {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .stroke(Color(.systemGray4).opacity(0.45), lineWidth: 0.5)
                )
        }
    }

    private struct HeatmapLayout {
        let weeks: [[Date]]
        let monthLabels: [String]
        let weekdayLabels: [String?]
        let palette: [Color]
        let levels: Int
        let calendar: Calendar
        let showLegend: Bool
        private let levelByDate: [Date: Int]

        init(chart: CodeAgentsUIHeatmapChart) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            calendar.firstWeekday = chart.weekStart == .mon ? 2 : 1
            self.calendar = calendar

            var levels = max(2, chart.levels)
            var palette = chart.palette.compactMap { Color(hex: $0) }
            if palette.count < levels {
                palette = HeatmapLayout.fallbackPalette
            }
            if levels > palette.count {
                levels = palette.count
            }
            self.levels = levels
            self.palette = palette
            showLegend = palette.count >= 2

            let levelByDate = HeatmapLayout.levelsByDate(chart: chart, calendar: calendar)
            self.levelByDate = levelByDate

            let sortedDates = chart.days.map { calendar.startOfDay(for: $0.date) }.sorted()
            guard let minDate = sortedDates.first, let maxDate = sortedDates.last else {
                weeks = []
                monthLabels = []
                weekdayLabels = HeatmapLayout.weekdayLabels(for: chart.weekStart)
                return
            }

            let gridStart = HeatmapLayout.alignToWeekStart(minDate, calendar: calendar)
            let gridEnd = HeatmapLayout.alignToWeekEnd(maxDate, calendar: calendar)
            let dayCount = calendar.dateComponents([.day], from: gridStart, to: gridEnd).day ?? 0
            let totalDays = max(0, dayCount + 1)
            let weekCount = max(1, totalDays / 7)

            var weeks: [[Date]] = []
            weeks.reserveCapacity(weekCount)

            for weekIndex in 0..<weekCount {
                var week: [Date] = []
                week.reserveCapacity(7)
                for dayIndex in 0..<7 {
                    let offset = weekIndex * 7 + dayIndex
                    if let date = calendar.date(byAdding: .day, value: offset, to: gridStart) {
                        week.append(date)
                    }
                }
                if week.count == 7 {
                    weeks.append(week)
                }
            }

            self.weeks = weeks
            self.monthLabels = HeatmapLayout.monthLabels(for: weeks, calendar: calendar)
            self.weekdayLabels = HeatmapLayout.weekdayLabels(for: chart.weekStart)
        }

        func color(for date: Date) -> Color {
            let key = calendar.startOfDay(for: date)
            let level = levelByDate[key] ?? 0
            let index = min(max(level, 0), palette.count - 1)
            return palette[index]
        }

        func accessibilityLabel(for date: Date, row: Int) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            let dateString = formatter.string(from: date)
            let value = levelByDate[calendar.startOfDay(for: date)] ?? 0
            return "\(dateString) level \(value)"
        }

        private static func levelsByDate(chart: CodeAgentsUIHeatmapChart, calendar: Calendar) -> [Date: Int] {
            var valueByDate: [Date: (value: Double?, level: Int?)] = [:]
            for day in chart.days {
                let key = calendar.startOfDay(for: day.date)
                valueByDate[key] = (day.value, day.level)
            }

            let maxValue = chart.maxValue ?? valueByDate.values.compactMap { $0.value }.max() ?? 0
            let maxValueSafe = max(0, maxValue)
            let levels = max(2, chart.levels)

            var levelsByDate: [Date: Int] = [:]
            for (date, entry) in valueByDate {
                if let explicit = entry.level {
                    levelsByDate[date] = min(max(explicit, 0), levels - 1)
                    continue
                }
                if let value = entry.value, maxValueSafe > 0 {
                    if value <= 0 {
                        levelsByDate[date] = 0
                    } else {
                        let fraction = min(value / maxValueSafe, 1)
                        let scaled = fraction * Double(levels - 1)
                        let computed = max(1, Int(ceil(scaled)))
                        levelsByDate[date] = min(computed, levels - 1)
                    }
                } else {
                    levelsByDate[date] = 0
                }
            }
            return levelsByDate
        }

        private static func alignToWeekStart(_ date: Date, calendar: Calendar) -> Date {
            let startOfDay = calendar.startOfDay(for: date)
            let weekday = calendar.component(.weekday, from: startOfDay)
            let delta = (weekday - calendar.firstWeekday + 7) % 7
            return calendar.date(byAdding: .day, value: -delta, to: startOfDay) ?? startOfDay
        }

        private static func alignToWeekEnd(_ date: Date, calendar: Calendar) -> Date {
            let startOfDay = calendar.startOfDay(for: date)
            let weekday = calendar.component(.weekday, from: startOfDay)
            let delta = (calendar.firstWeekday + 6 - weekday + 7) % 7
            return calendar.date(byAdding: .day, value: delta, to: startOfDay) ?? startOfDay
        }

        private static func weekdayLabels(for weekStart: CodeAgentsUIHeatmapWeekStart) -> [String?] {
            var labels: [String?] = Array(repeating: nil, count: 7)
            if weekStart == .mon {
                labels[0] = "Mon"
                labels[2] = "Wed"
                labels[4] = "Fri"
            } else {
                labels[1] = "Mon"
                labels[3] = "Wed"
                labels[5] = "Fri"
            }
            return labels
        }

        private static func monthLabels(for weeks: [[Date]], calendar: Calendar) -> [String] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "MMM"

            var labels: [String] = []
            labels.reserveCapacity(weeks.count)

            var previousMonth: Int?
            for week in weeks {
                guard let date = week.first else {
                    labels.append("")
                    continue
                }
                let month = calendar.component(.month, from: date)
                if previousMonth == nil || previousMonth != month {
                    labels.append(formatter.string(from: date))
                    previousMonth = month
                } else {
                    labels.append("")
                }
            }
            return labels
        }

        private static let fallbackPalette: [Color] = [
            Color(hex: "#ebedf0"),
            Color(hex: "#9be9a8"),
            Color(hex: "#40c463"),
            Color(hex: "#30a14e"),
            Color(hex: "#216e39")
        ].compactMap { $0 }
    }
}
