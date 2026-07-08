//
//  CodeAgentsUITableView.swift
//  CodeAgentsMobile
//
//  Purpose: Table/grid/zoom widgets for codeagents_ui blocks
//

import SwiftUI
import UIKit

struct CodeAgentsUITableView: View {
    let table: CodeAgentsUITable
    @State private var showExpanded = false
    @State private var copyFeedback: String?

    var body: some View {
        let columnCount = table.columns.count
        if columnCount == 0 || table.rows.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                tableHeader

                CodeAgentsUITableGrid(
                    table: table,
                    rows: previewRows,
                    mode: .preview,
                    zoom: 1,
                    sortColumn: nil,
                    sortAscending: true,
                    onHeaderTap: nil
                )

                if hiddenRowCount > 0 {
                    Button {
                        showExpanded = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.semibold))
                            Text("Open full table to view \(hiddenRowCount) more rows")
                                .font(.caption.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .background(Color(.systemGray6).opacity(0.55))
                }
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(.systemGray4).opacity(0.7), lineWidth: 0.5)
            )
            .sheet(isPresented: $showExpanded) {
                CodeAgentsUITableDetailSheet(table: table)
            }
        }
    }

    private var previewRows: [[String]] {
        Array(table.rows.prefix(5))
    }

    private var hiddenRowCount: Int {
        max(0, table.rows.count - previewRows.count)
    }

    private var title: String {
        let trimmed = table.caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Table" : trimmed
    }

    private var tableHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(tableSummary)
                    if let copyFeedback {
                        Text(copyFeedback)
                            .foregroundColor(.accentColor)
                    }
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                showExpanded = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.callout.weight(.semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .accessibilityLabel("Open full table")

            Menu {
                Button {
                    copy(CodeAgentsUITableExport.tsv(table), feedback: "Copied TSV")
                } label: {
                    Label("Copy TSV", systemImage: "doc.on.doc")
                }

                Button {
                    copy(CodeAgentsUITableExport.markdown(table), feedback: "Copied Markdown")
                } label: {
                    Label("Copy Markdown", systemImage: "text.badge.checkmark")
                }

                Button {
                    let didExport = CodeAgentsUITableActions.exportCSV(table)
                    showFeedback(didExport ? "Exporting CSV" : "Export failed")
                } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(width: 30, height: 30)
            }
            .foregroundColor(.accentColor)
            .accessibilityLabel("Table actions")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    private var tableSummary: String {
        let rowWord = table.rows.count == 1 ? "row" : "rows"
        let columnWord = table.columns.count == 1 ? "column" : "columns"
        return "\(table.rows.count) \(rowWord), \(table.columns.count) \(columnWord)"
    }

    private func copy(_ value: String, feedback: String) {
        UIPasteboard.general.string = value
        showFeedback(feedback)
    }

    private func showFeedback(_ value: String) {
        copyFeedback = value

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if copyFeedback == value {
                copyFeedback = nil
            }
        }
    }
}

struct CodeAgentsUITableDetailSheet: View {
    let table: CodeAgentsUITable
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var sortColumn: Int?
    @State private var sortAscending = true
    @State private var zoom: CodeAgentsUITableZoom = .fit
    @State private var feedback: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                detailSummary

                CodeAgentsUITableGrid(
                    table: table,
                    rows: visibleRows,
                    mode: .detail,
                    zoom: zoom.scale,
                    sortColumn: sortColumn,
                    sortAscending: sortAscending,
                    onHeaderTap: toggleSort
                )
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search table"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Picker("Zoom", selection: $zoom) {
                            ForEach(CodeAgentsUITableZoom.allCases) { value in
                                Text(value.title).tag(value)
                            }
                        }

                        Divider()

                        Button {
                            copy(CodeAgentsUITableExport.tsv(table), feedback: "Copied TSV")
                        } label: {
                            Label("Copy TSV", systemImage: "doc.on.doc")
                        }

                        Button {
                            copy(CodeAgentsUITableExport.markdown(table), feedback: "Copied Markdown")
                        } label: {
                            Label("Copy Markdown", systemImage: "text.badge.checkmark")
                        }

                        Button {
                            let didExport = CodeAgentsUITableActions.exportCSV(table)
                            showFeedback(didExport ? "Exporting CSV" : "Export failed")
                        } label: {
                            Label("Export CSV", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Table actions")
                }
            }
        }
    }

    private var title: String {
        let trimmed = table.caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Table" : trimmed
    }

    private var detailSummary: some View {
        HStack(spacing: 8) {
            Text(visibleSummary)
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            if let feedback {
                Text(feedback)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(.systemGray4).opacity(0.55))
                .frame(height: 0.5)
        }
    }

    private var visibleSummary: String {
        let rowWord = visibleRows.count == 1 ? "row" : "rows"
        let columnWord = table.columns.count == 1 ? "column" : "columns"

        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(table.rows.count) \(rowWord), \(table.columns.count) \(columnWord)"
        }

        return "\(visibleRows.count) matching \(rowWord), \(table.columns.count) \(columnWord)"
    }

    private var visibleRows: [[String]] {
        let filteredRows = filteredRows()

        guard let sortColumn else {
            return filteredRows
        }

        return Array(filteredRows.enumerated())
            .sorted { left, right in
                let result = compare(
                    value(at: sortColumn, in: left.element),
                    value(at: sortColumn, in: right.element)
                )

                if result == .orderedSame {
                    return left.offset < right.offset
                }

                return sortAscending ? result == .orderedAscending : result == .orderedDescending
            }
            .map(\.element)
    }

    private func filteredRows() -> [[String]] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return table.rows
        }

        return table.rows.filter { row in
            row.contains { value in
                value.localizedCaseInsensitiveContains(needle)
            }
        }
    }

    private func value(at index: Int, in row: [String]) -> String {
        index < row.count ? row[index] : ""
    }

    private func compare(_ left: String, _ right: String) -> ComparisonResult {
        let leftTrimmed = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let rightTrimmed = right.trimmingCharacters(in: .whitespacesAndNewlines)

        if let leftNumber = Double(leftTrimmed.replacingOccurrences(of: ",", with: "")),
           let rightNumber = Double(rightTrimmed.replacingOccurrences(of: ",", with: "")) {
            if leftNumber < rightNumber { return .orderedAscending }
            if leftNumber > rightNumber { return .orderedDescending }
            return .orderedSame
        }

        return leftTrimmed.localizedCaseInsensitiveCompare(rightTrimmed)
    }

    private func toggleSort(column: Int) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = true
        }
    }

    private func copy(_ value: String, feedback: String) {
        UIPasteboard.general.string = value
        showFeedback(feedback)
    }

    private func showFeedback(_ value: String) {
        feedback = value

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if feedback == value {
                feedback = nil
            }
        }
    }
}

enum CodeAgentsUITableGridMode {
    case preview
    case detail

    var headerFontSize: CGFloat {
        switch self {
        case .preview:
            return 13
        case .detail:
            return 15
        }
    }

    var bodyFontSize: CGFloat {
        switch self {
        case .preview:
            return 14
        case .detail:
            return 15
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .preview:
            return 10
        case .detail:
            return 12
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .preview:
            return 8
        case .detail:
            return 10
        }
    }

    var minRowHeight: CGFloat {
        switch self {
        case .preview:
            return 42
        case .detail:
            return 48
        }
    }

    var lineLimit: Int? {
        switch self {
        case .preview:
            return 3
        case .detail:
            return 8
        }
    }
}

struct CodeAgentsUITableGrid: View {
    let table: CodeAgentsUITable
    let rows: [[String]]
    let mode: CodeAgentsUITableGridMode
    let zoom: CGFloat
    let sortColumn: Int?
    let sortAscending: Bool
    let onHeaderTap: ((Int) -> Void)?

    private var columnCount: Int {
        table.columns.count
    }

    var body: some View {
        let widths = CodeAgentsUITableLayout.columnWidths(
            columns: table.columns,
            rows: rows,
            mode: mode
        )

        ScrollView(scrollAxes, showsIndicators: true) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { index in
                        headerCell(
                            text: table.columns[index],
                            columnIndex: index,
                            width: widths[index]
                        )
                    }
                }

                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { columnIndex in
                            bodyCell(
                                text: value(at: columnIndex, in: row),
                                rowIndex: rowIndex,
                                width: widths[columnIndex]
                            )
                        }
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .background(Color(.systemBackground))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(.systemGray4).opacity(0.55))
                .frame(height: 0.5)
        }
    }

    private var scrollAxes: Axis.Set {
        mode == .preview ? .horizontal : [.horizontal, .vertical]
    }

    @ViewBuilder
    private func headerCell(text: String, columnIndex: Int, width: CGFloat) -> some View {
        let displayText = cleanedDisplayText(text)
        let cellWidth = textWidth(for: width)
        let cellHeight = mode.minRowHeight * zoom

        let content = HStack(spacing: 5) {
            Text(displayText)
                .font(.system(size: mode.headerFontSize * zoom, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .minimumScaleFactor(0.92)

            if sortColumn == columnIndex {
                Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)
        }
        .frame(minWidth: cellWidth, maxWidth: cellWidth, minHeight: cellHeight, alignment: .leading)
        .padding(.horizontal, mode.horizontalPadding)
        .padding(.vertical, mode.verticalPadding)

        if let onHeaderTap {
            Button {
                onHeaderTap(columnIndex)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .background(Color(.systemGray5).opacity(0.75))
            .overlay(Rectangle().stroke(borderColor, lineWidth: 0.5))
        } else {
            content
                .background(Color(.systemGray5).opacity(0.75))
                .overlay(Rectangle().stroke(borderColor, lineWidth: 0.5))
        }
    }

    private func bodyCell(text: String, rowIndex: Int, width: CGFloat) -> some View {
        let displayText = cleanedDisplayText(text)
        let cellWidth = textWidth(for: width)
        let cellHeight = mode.minRowHeight * zoom
        let background = rowIndex.isMultiple(of: 2) ? Color(.systemBackground) : Color(.systemGray6).opacity(0.5)

        return Text(displayText)
            .font(.system(size: mode.bodyFontSize * zoom))
            .foregroundColor(.primary)
            .lineLimit(mode.lineLimit)
            .multilineTextAlignment(.leading)
            .minimumScaleFactor(0.9)
            .frame(minWidth: cellWidth, maxWidth: cellWidth, minHeight: cellHeight, alignment: .topLeading)
            .padding(.horizontal, mode.horizontalPadding)
            .padding(.vertical, mode.verticalPadding)
            .background(background)
            .overlay(Rectangle().stroke(borderColor, lineWidth: 0.5))
    }

    private var borderColor: Color {
        Color(.systemGray4).opacity(0.55)
    }

    private func textWidth(for width: CGFloat) -> CGFloat {
        max(44, width * zoom - (mode.horizontalPadding * 2))
    }

    private func value(at index: Int, in row: [String]) -> String {
        index < row.count ? row[index] : ""
    }

    private func cleanedDisplayText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .joined(separator: mode == .preview ? " " : "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CodeAgentsUITableLayout {
    static func columnWidths(
        columns: [String],
        rows: [[String]],
        mode: CodeAgentsUITableGridMode
    ) -> [CGFloat] {
        columns.enumerated().map { index, column in
            widthForColumn(index: index, title: column, rows: rows, mode: mode)
        }
    }

    private static func widthForColumn(
        index: Int,
        title: String,
        rows: [[String]],
        mode: CodeAgentsUITableGridMode
    ) -> CGFloat {
        let samples = ([title] + rows.prefix(30).map { row in
            index < row.count ? row[index] : ""
        })
        .map(normalizedSample)

        let titleLowercased = title.lowercased()
        let maxCharacters = samples.map(\.count).max() ?? 0
        let hasLongText = samples.contains { $0.count > 34 }
        let isNumeric = rowsHaveNumericValues(rows: rows, columnIndex: index)

        if isNumeric || titleLowercased == "id" || titleLowercased.contains("http") {
            return clamp(CGFloat(max(maxCharacters, title.count)) * 7.5 + 40, min: 76, max: 112)
        }

        if titleLowercased.contains("date")
            || titleLowercased.contains("expiry")
            || titleLowercased.contains("expires") {
            return mode == .preview ? 132 : 150
        }

        if titleLowercased.contains("feature")
            || titleLowercased.contains("description")
            || titleLowercased.contains("notes")
            || hasLongText {
            return mode == .preview ? 240 : 320
        }

        if index == 0 {
            return clamp(CGFloat(maxCharacters) * 7.4 + 52, min: 150, max: mode == .preview ? 220 : 280)
        }

        return clamp(CGFloat(maxCharacters) * 7.4 + 48, min: 118, max: mode == .preview ? 190 : 240)
    }

    private static func rowsHaveNumericValues(rows: [[String]], columnIndex: Int) -> Bool {
        let values = rows.prefix(20).compactMap { row -> String? in
            guard columnIndex < row.count else { return nil }
            let value = row[columnIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        guard !values.isEmpty else { return false }

        return values.allSatisfy { value in
            Double(value.replacingOccurrences(of: ",", with: "")) != nil
        }
    }

    private static func normalizedSample(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clamp(_ value: CGFloat, min minimum: CGFloat, max maximum: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minimum), maximum)
    }
}

enum CodeAgentsUITableZoom: String, CaseIterable, Identifiable {
    case fit
    case normal
    case large
    case extraLarge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit:
            return "Fit"
        case .normal:
            return "100%"
        case .large:
            return "125%"
        case .extraLarge:
            return "150%"
        }
    }

    var scale: CGFloat {
        switch self {
        case .fit, .normal:
            return 1
        case .large:
            return 1.25
        case .extraLarge:
            return 1.5
        }
    }
}

enum CodeAgentsUITableActions {
    static func exportCSV(_ table: CodeAgentsUITable) -> Bool {
        guard let url = writeCSV(table) else {
            return false
        }

        ShareSheetPresenter.present(urls: [url]) {
            try? FileManager.default.removeItem(at: url)
        }
        return true
    }

    private static func writeCSV(_ table: CodeAgentsUITable) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName(for: table))
            .appendingPathExtension("csv")

        do {
            try CodeAgentsUITableExport.csv(table).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func fileName(for table: CodeAgentsUITable) -> String {
        let rawName = table.caption?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? table.caption ?? table.id
            : table.id

        let cleaned = rawName.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "-"
        }

        let name = String(cleaned)
            .split(separator: "-")
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return String((name.isEmpty ? "table" : name).prefix(64))
    }
}
