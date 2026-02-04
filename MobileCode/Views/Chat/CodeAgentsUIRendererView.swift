//
//  CodeAgentsUIRendererView.swift
//  CodeAgentsMobile
//
//  Purpose: Render codeagents_ui blocks as SwiftUI widgets.
//

import SwiftUI
import AVKit
import Charts
import UIKit

struct CodeAgentsUIRendererView: View {
    let block: CodeAgentsUIBlock
    let project: RemoteProject?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = block.title, !title.isEmpty {
                Text(title)
                    .font(.headline)
            }

            ForEach(block.elements, id: \.id) { element in
                elementView(element)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func elementView(_ element: CodeAgentsUIElement) -> some View {
        switch element {
        case .card(let card):
            CodeAgentsUICardView(card: card, project: project)
        case .markdown(let markdown):
            FullMarkdownTextView(text: markdown.text)
        case .image(let image):
            CodeAgentsUIImageView(image: image, project: project)
        case .gallery(let gallery):
            CodeAgentsUIGalleryView(gallery: gallery, project: project)
        case .video(let video):
            CodeAgentsUIVideoView(video: video, project: project)
        case .table(let table):
            CodeAgentsUITableView(table: table)
        case .chart(let chart):
            CodeAgentsUIChartView(chart: chart)
        }
    }
}

private struct CodeAgentsUICardView: View {
    let card: CodeAgentsUICard
    let project: RemoteProject?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = card.title, !title.isEmpty {
                Text(title)
                    .font(.headline)
            }
            if let subtitle = card.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            if !card.content.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(card.content, id: \.id) { element in
                        CodeAgentsUIRendererView(block: CodeAgentsUIBlock(title: nil, elements: [element]), project: project)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.systemGray4).opacity(0.4), lineWidth: 0.5)
        )
    }
}

private struct CodeAgentsUIMediaPreviewPayload: Identifiable {
    let id = UUID()
    let urls: [URL]
    let startIndex: Int
}

private struct CodeAgentsUIImageView: View {
    let image: CodeAgentsUIImage
    let project: RemoteProject?
    @State private var previewPayload: CodeAgentsUIMediaPreviewPayload?
    @State private var isPreparingPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CodeAgentsUIMediaImageView(
                source: image.source,
                project: project,
                aspectRatio: image.aspectRatio
            )
            if let caption = image.caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            openPreview()
        }
        .sheet(item: $previewPayload) { payload in
            CodeAgentsUIMediaPreviewController(urls: payload.urls, startIndex: payload.startIndex)
        }
    }

    private func openPreview() {
        guard !isPreparingPreview else { return }
        isPreparingPreview = true
        Task {
            let project = project ?? ProjectContext.shared.activeProject
            let urls = await ChatMediaLoader.shared.preparePreviewItems(sources: [image.source], project: project)
            let existing = urls.filter { fileURLExists($0) }
            await MainActor.run {
                if let first = existing.first {
                    previewPayload = CodeAgentsUIMediaPreviewPayload(urls: [first], startIndex: 0)
                }
                isPreparingPreview = false
            }
        }
    }
}

private struct CodeAgentsUIGalleryView: View {
    let gallery: CodeAgentsUIGallery
    let project: RemoteProject?
    @State private var previewPayload: CodeAgentsUIMediaPreviewPayload?
    @State private var isPreparingPreview = false
    private let thumbnailHeight: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(gallery.images.enumerated()), id: \.element.id) { index, image in
                        let ratio = image.aspectRatio ?? CodeAgentsUIMediaImageView.fallbackAspectRatio
                        CodeAgentsUIMediaImageView(
                            source: image.source,
                            project: project,
                            aspectRatio: image.aspectRatio
                        )
                        .frame(width: thumbnailHeight * ratio, height: thumbnailHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            openPreview(startIndex: index)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            if let caption = gallery.caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .sheet(item: $previewPayload) { payload in
            CodeAgentsUIMediaPreviewController(urls: payload.urls, startIndex: payload.startIndex)
        }
    }

    private func openPreview(startIndex: Int) {
        guard !isPreparingPreview else { return }
        isPreparingPreview = true
        Task {
            let project = project ?? ProjectContext.shared.activeProject
            let sources = gallery.images.map { $0.source }
            var resolved: [URL] = []
            resolved.reserveCapacity(sources.count)
            var indexMap: [Int: Int] = [:]
            for (idx, source) in sources.enumerated() {
                if let url = await ChatMediaLoader.shared.preparePreviewURL(for: source, project: project) {
                    if fileURLExists(url) {
                        indexMap[idx] = resolved.count
                        resolved.append(url)
                    }
                }
            }

            await MainActor.run {
                if let mappedIndex = indexMap[startIndex], !resolved.isEmpty {
                    previewPayload = CodeAgentsUIMediaPreviewPayload(urls: resolved, startIndex: mappedIndex)
                }
                isPreparingPreview = false
            }
        }
    }
}

private struct CodeAgentsUIVideoView: View {
    let video: CodeAgentsUIVideo
    let project: RemoteProject?
    @State private var previewPayload: CodeAgentsUIMediaPreviewPayload?
    @State private var isPreparingPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CodeAgentsUIMediaVideoView(source: video.source, poster: video.poster, project: project)
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            if let caption = video.caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            openPreview()
        }
        .sheet(item: $previewPayload) { payload in
            CodeAgentsUIMediaPreviewController(urls: payload.urls, startIndex: payload.startIndex)
        }
    }

    private func openPreview() {
        guard !isPreparingPreview else { return }
        isPreparingPreview = true
        Task {
            let project = project ?? ProjectContext.shared.activeProject
            let urls = await ChatMediaLoader.shared.preparePreviewItems(sources: [video.source], project: project)
            let existing = urls.filter { fileURLExists($0) }
            await MainActor.run {
                if let first = existing.first {
                    previewPayload = CodeAgentsUIMediaPreviewPayload(urls: [first], startIndex: 0)
                }
                isPreparingPreview = false
            }
        }
    }
}

private func fileURLExists(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    return exists && !isDirectory.boolValue
}

private struct CodeAgentsUIMediaImageView: View {
    static let fallbackAspectRatio: Double = 4.0 / 3.0

    let source: CodeAgentsUIMediaSource
    let project: RemoteProject?
    let aspectRatio: Double?

    @State private var resolved: CodeAgentsUIMediaResolved?
    @State private var didFail = false

    var body: some View {
        let ratio = containerAspectRatio
        return ZStack {
            if let resolved {
                imageView(for: resolved)
            } else if didFail {
                EmptyView()
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color(.systemGray6).opacity(0.25))
        .aspectRatio(ratio, contentMode: .fit)
        .task {
            guard resolved == nil, !didFail else { return }
            let resolved = await ChatMediaLoader.shared.resolveMedia(source, project: project ?? ProjectContext.shared.activeProject)
            if let resolved {
                self.resolved = resolved
            } else {
                didFail = true
            }
        }
    }

    @ViewBuilder
    private func imageView(for resolved: CodeAgentsUIMediaResolved) -> some View {
        switch resolved {
        case .remote(let url):
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    formattedImage(image.resizable())
                case .failure(_):
                    EmptyView()
                default:
                    ProgressView()
                }
            }
        case .local(let url):
            if let uiImage = UIImage(contentsOfFile: url.path) {
                formattedImage(Image(uiImage: uiImage).resizable())
            } else {
                EmptyView()
            }
        }
    }

    private func formattedImage(_ image: Image) -> some View {
        AnyView(
            image
                .scaledToFit()
                .frame(maxWidth: .infinity)
        )
    }

    private var containerAspectRatio: Double {
        let ratio = aspectRatio ?? Self.fallbackAspectRatio
        if ratio <= 0 {
            return Self.fallbackAspectRatio
        }
        return ratio
    }
}

private struct CodeAgentsUIMediaVideoView: View {
    let source: CodeAgentsUIMediaSource
    let poster: CodeAgentsUIMediaSource?
    let project: RemoteProject?

    @State private var resolved: CodeAgentsUIMediaResolved?
    @State private var didFail = false

    var body: some View {
        Group {
            if let resolved {
                videoView(for: resolved)
            } else if didFail {
                EmptyView()
            } else if let poster {
                CodeAgentsUIMediaImageView(source: poster, project: project, aspectRatio: nil)
            } else {
                ProgressView()
            }
        }
        .task {
            guard resolved == nil, !didFail else { return }
            let resolved = await ChatMediaLoader.shared.resolveMedia(source, project: project ?? ProjectContext.shared.activeProject)
            if let resolved {
                self.resolved = resolved
            } else {
                didFail = true
            }
        }
    }

    private func videoView(for resolved: CodeAgentsUIMediaResolved) -> some View {
        switch resolved {
        case .remote(let url):
            return VideoPlayer(player: AVPlayer(url: url))
        case .local(let url):
            return VideoPlayer(player: AVPlayer(url: url))
        }
    }
}

private struct CodeAgentsUITableView: View {
    let table: CodeAgentsUITable

    var body: some View {
        let columnCount = table.columns.count
        if columnCount == 0 || table.rows.isEmpty {
            EmptyView()
        } else {
            let borderColor = Color(.systemGray4).opacity(0.6)
            let headerBackground = Color(.systemGray5).opacity(0.7)
            let stripeBackground = Color(.systemGray5).opacity(0.35)
            let columnWidth = preferredColumnWidth(columnCount: columnCount)

            ScrollView(.horizontal, showsIndicators: false) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { index in
                            FullMarkdownTextView(text: table.columns[index])
                                .font(.subheadline.weight(.semibold))
                                .padding(.vertical, 8)
                                .padding(.horizontal, 10)
                                .frame(width: columnWidth, alignment: .leading)
                                .background(headerBackground)
                                .overlay(Rectangle().stroke(borderColor, lineWidth: 0.5))
                        }
                    }

                    ForEach(0..<table.rows.count, id: \.self) { rowIndex in
                        let row = table.rows[rowIndex]
                        GridRow {
                            ForEach(0..<columnCount, id: \.self) { columnIndex in
                                let cellText = columnIndex < row.count ? row[columnIndex] : ""
                                FullMarkdownTextView(text: cellText)
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 10)
                                    .frame(width: columnWidth, alignment: .leading)
                                    .background(rowIndex.isMultiple(of: 2) ? Color.clear : stripeBackground)
                                    .overlay(Rectangle().stroke(borderColor, lineWidth: 0.5))
                            }
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(borderColor, lineWidth: 0.5)
            )
        }
    }

    private func preferredColumnWidth(columnCount: Int) -> CGFloat {
        let minimumColumnWidth: CGFloat = 90
        let maximumColumnWidth: CGFloat = 220
        let padded = CGFloat(320 / max(1, columnCount))
        return min(max(padded, minimumColumnWidth), maximumColumnWidth)
    }
}

private struct CodeAgentsUIChartView: View {
    let chart: CodeAgentsUIChart

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = chart.title, !title.isEmpty {
                Text(title)
                    .font(.headline)
            }
            if let subtitle = chart.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            switch chart.kind {
            case .barLine(let barLine):
                barLineChart(barLine)
            case .pie(let pie):
                pieChart(pie)
            case .heatmap(let heatmap):
                heatmapChart(heatmap)
            }
        }
    }

    @ViewBuilder
    private func barLineChart(_ chart: CodeAgentsUIBarLineChart) -> some View {
        Chart {
            ForEach(Array(chart.series.enumerated()), id: \.offset) { seriesIndex, series in
                ForEach(Array(chart.x.enumerated()), id: \.offset) { index, label in
                    if index < series.values.count, let value = series.values[index] {
                        if chart.chartType == .bar {
                            BarMark(
                                x: .value("X", label),
                                y: .value("Value", value)
                            )
                            .foregroundStyle(colorForSeries(series, fallbackIndex: seriesIndex))
                        } else {
                            LineMark(
                                x: .value("X", label),
                                y: .value("Value", value)
                            )
                            .foregroundStyle(colorForSeries(series, fallbackIndex: seriesIndex))
                        }
                    }
                }
            }
        }
        .frame(height: 220)
        .chartLegend(position: .bottom, alignment: .leading)
    }

    @ViewBuilder
    private func pieChart(_ chart: CodeAgentsUIPieChart) -> some View {
        let total = chart.slices.reduce(0) { $0 + $1.value }
        Chart {
            ForEach(Array(chart.slices.enumerated()), id: \.offset) { index, slice in
                SectorMark(angle: .value("Value", slice.value))
                    .foregroundStyle(colorForSlice(slice, fallbackIndex: index))
            }
        }
        .frame(height: 220)
        .chartLegend(position: .bottom, alignment: .leading)

        if chart.valueDisplay != .none {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(chart.slices.enumerated()), id: \.offset) { index, slice in
                    let percent = total > 0 ? (slice.value / total) : 0
                    let text = pieDisplayText(slice: slice, percent: percent, display: chart.valueDisplay)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(colorForSlice(slice, fallbackIndex: index))
                            .frame(width: 8, height: 8)
                        Text(text)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func heatmapChart(_ chart: CodeAgentsUIHeatmapChart) -> some View {
        CodeAgentsUIHeatmapView(chart: chart)
    }

    private func pieDisplayText(slice: CodeAgentsUIPieSlice, percent: Double, display: CodeAgentsUIPieValueDisplay) -> String {
        switch display {
        case .value:
            return "\(slice.label): \(slice.value)"
        case .both:
            return "\(slice.label): \(slice.value) (\(Int(percent * 100))%)"
        case .percent:
            return "\(slice.label): \(Int(percent * 100))%"
        case .none:
            return slice.label
        }
    }

    private func colorForSeries(_ series: CodeAgentsUIChartSeries, fallbackIndex: Int) -> Color {
        if let color = series.color, let parsed = Color(hex: color) {
            return parsed
        }
        return fallbackPaletteColor(index: fallbackIndex)
    }

    private func colorForSlice(_ slice: CodeAgentsUIPieSlice, fallbackIndex: Int) -> Color {
        if let color = slice.color, let parsed = Color(hex: color) {
            return parsed
        }
        return fallbackPaletteColor(index: fallbackIndex)
    }

    private func fallbackPaletteColor(index: Int) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo]
        return palette[index % palette.count]
    }
}

private struct CodeAgentsUIHeatmapView: View {
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

private extension Color {
    init?(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexString.hasPrefix("#") {
            hexString.removeFirst()
        }
        guard hexString.count == 6,
              let intValue = Int(hexString, radix: 16) else {
            return nil
        }
        let red = Double((intValue >> 16) & 0xFF) / 255.0
        let green = Double((intValue >> 8) & 0xFF) / 255.0
        let blue = Double(intValue & 0xFF) / 255.0
        self = Color(red: red, green: green, blue: blue)
    }
}
