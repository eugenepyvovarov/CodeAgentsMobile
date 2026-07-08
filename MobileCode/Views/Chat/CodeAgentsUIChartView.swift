//
//  CodeAgentsUIChartView.swift
//  CodeAgentsMobile
//
//  Purpose: Chart widgets for codeagents_ui blocks
//

import SwiftUI
import Charts

struct CodeAgentsUIChartView: View {
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
