//
//  CodeAgentsUITableView.swift
//  CodeAgentsMobile
//
//  Purpose: Table/grid/zoom widgets for codeagents_ui blocks
//

import SwiftUI
import UIKit

// MARK: - Preview card

struct CodeAgentsUITableView: View {
    let table: CodeAgentsUITable

    @State private var showExpanded = false
    @State private var copyFeedback: String?

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

    private var tableSummary: String {
        let rowWord = table.rows.count == 1 ? "row" : "rows"
        let columnWord = table.columns.count == 1 ? "col" : "cols"
        return "\(table.rows.count) \(rowWord) · \(table.columns.count) \(columnWord)"
    }

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
                    moreRowsButton
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .modifier(CodeAgentsUITableSurfaceModifier())
            .sheet(isPresented: $showExpanded) {
                CodeAgentsUITableDetailSheet(table: table)
            }
        }
    }

    // MARK: Header

    private var tableHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "tablecells")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 14)

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(tableSummary)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            if let copyFeedback {
                Text(copyFeedback)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .transition(.opacity)
            }

            Spacer(minLength: 4)

            Button {
                showExpanded = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
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
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("Table actions")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(.secondarySystemFill).opacity(0.35))
    }

    private var moreRowsButton: some View {
        Button {
            showExpanded = true
        } label: {
            HStack(spacing: 4) {
                Text("+\(hiddenRowCount) more")
                    .font(.caption2.weight(.semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color(.secondarySystemFill).opacity(0.22))
        .accessibilityLabel("Open full table, \(hiddenRowCount) more rows")
    }

    private func copy(_ value: String, feedback: String) {
        UIPasteboard.general.string = value
        showFeedback(feedback)
    }

    private func showFeedback(_ value: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            copyFeedback = value
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if copyFeedback == value {
                withAnimation(.easeInOut(duration: 0.15)) {
                    copyFeedback = nil
                }
            }
        }
    }
}

// MARK: - Detail sheet

struct CodeAgentsUITableDetailSheet: View {
    let table: CodeAgentsUITable

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var sortColumn: Int?
    @State private var sortAscending = true
    @State private var zoom: CodeAgentsUITableZoom = .fit
    @State private var feedback: String?

    private var title: String {
        let trimmed = table.caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Table" : trimmed
    }

    private var visibleSummary: String {
        let rowWord = visibleRows.count == 1 ? "row" : "rows"
        let columnWord = table.columns.count == 1 ? "col" : "cols"

        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(table.rows.count) \(rowWord) · \(table.columns.count) \(columnWord)"
        }

        return "\(visibleRows.count) matching · \(table.columns.count) \(columnWord)"
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

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    private var detailSummary: some View {
        HStack(spacing: 8) {
            Text(visibleSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if let feedback {
                Text(feedback)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemFill).opacity(0.28))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(.separator).opacity(0.45))
                .frame(height: 0.5)
        }
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

// MARK: - Grid metrics

enum CodeAgentsUITableGridMode {
    case preview
    case detail

    var headerFontSize: CGFloat {
        switch self {
        case .preview: return 11
        case .detail: return 13
        }
    }

    var bodyFontSize: CGFloat {
        switch self {
        case .preview: return 12
        case .detail: return 14
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .preview: return 8
        case .detail: return 10
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .preview: return 5
        case .detail: return 7
        }
    }

    var minRowHeight: CGFloat {
        switch self {
        case .preview: return 30
        case .detail: return 38
        }
    }

    var lineLimit: Int? {
        switch self {
        case .preview: return 2
        case .detail: return 6
        }
    }
}

// MARK: - Grid

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

    private var scrollAxes: Axis.Set {
        mode == .preview ? .horizontal : [.horizontal, .vertical]
    }

    private var hairline: Color {
        Color(.separator).opacity(0.35)
    }

    var body: some View {
        let widths = CodeAgentsUITableLayout.columnWidths(
            columns: table.columns,
            rows: rows,
            mode: mode
        )
        let alignments = CodeAgentsUITableLayout.columnAlignments(
            columns: table.columns,
            rows: rows
        )

        // Detail fullscreen: pin short tables to top-leading. Dual-axis ScrollView
        // otherwise centers content when the grid is smaller than the viewport.
        if mode == .detail {
            GeometryReader { proxy in
                ScrollView(scrollAxes, showsIndicators: true) {
                    tableGrid(widths: widths, alignments: alignments)
                        .fixedSize(horizontal: true, vertical: true)
                        .frame(
                            minWidth: proxy.size.width,
                            minHeight: proxy.size.height,
                            alignment: .topLeading
                        )
                }
                .defaultScrollAnchor(.topLeading)
            }
            .background(Color(.systemBackground))
        } else {
            ScrollView(scrollAxes, showsIndicators: false) {
                tableGrid(widths: widths, alignments: alignments)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .background(Color(.systemBackground).opacity(0.55))
        }
    }

    @ViewBuilder
    private func tableGrid(widths: [CGFloat], alignments: [TextAlignment]) -> some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<columnCount, id: \.self) { index in
                    headerCell(
                        text: table.columns[index],
                        columnIndex: index,
                        width: widths[index],
                        alignment: alignments[index]
                    )
                }
            }

            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { columnIndex in
                        bodyCell(
                            text: value(at: columnIndex, in: row),
                            rowIndex: rowIndex,
                            columnIndex: columnIndex,
                            width: widths[columnIndex],
                            alignment: alignments[columnIndex],
                            isLastRow: rowIndex == rows.count - 1
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func headerCell(
        text: String,
        columnIndex: Int,
        width: CGFloat,
        alignment: TextAlignment
    ) -> some View {
        let displayText = cleanedDisplayText(text)
        let cellWidth = textWidth(for: width)
        let cellHeight = mode.minRowHeight * zoom

        let content = HStack(spacing: 3) {
            if alignment == .trailing {
                Spacer(minLength: 0)
            }

            Text(displayText)
                .font(.system(size: mode.headerFontSize * zoom, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(alignment)

            if sortColumn == columnIndex {
                Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }

            if alignment != .trailing {
                Spacer(minLength: 0)
            }
        }
        .frame(minWidth: cellWidth, maxWidth: cellWidth, minHeight: cellHeight, alignment: .leading)
        .padding(.horizontal, mode.horizontalPadding)
        .padding(.vertical, mode.verticalPadding)
        .background(Color(.secondarySystemFill).opacity(0.45))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(hairline)
                .frame(height: 0.5)
        }
        .overlay(alignment: .trailing) {
            if columnIndex < columnCount - 1 {
                Rectangle()
                    .fill(hairline.opacity(0.7))
                    .frame(width: 0.5)
            }
        }

        if let onHeaderTap {
            Button {
                onHeaderTap(columnIndex)
            } label: {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func bodyCell(
        text: String,
        rowIndex: Int,
        columnIndex: Int,
        width: CGFloat,
        alignment: TextAlignment,
        isLastRow: Bool
    ) -> some View {
        let displayText = cleanedDisplayText(text)
        let cellWidth = textWidth(for: width)
        let cellHeight = mode.minRowHeight * zoom
        let zebra = rowIndex.isMultiple(of: 2)
            ? Color.clear
            : Color(.secondarySystemFill).opacity(0.28)

        return Text(displayText)
            .font(.system(size: mode.bodyFontSize * zoom))
            .foregroundStyle(.primary.opacity(0.92))
            .lineLimit(mode.lineLimit)
            .multilineTextAlignment(alignment)
            .minimumScaleFactor(0.88)
            .frame(
                minWidth: cellWidth,
                maxWidth: cellWidth,
                minHeight: cellHeight,
                alignment: alignment == .trailing ? .topTrailing : .topLeading
            )
            .padding(.horizontal, mode.horizontalPadding)
            .padding(.vertical, mode.verticalPadding)
            .background(zebra)
            .overlay(alignment: .bottom) {
                if !isLastRow {
                    Rectangle()
                        .fill(hairline.opacity(0.65))
                        .frame(height: 0.5)
                }
            }
            .overlay(alignment: .trailing) {
                if columnIndex < columnCount - 1 {
                    Rectangle()
                        .fill(hairline.opacity(0.45))
                        .frame(width: 0.5)
                }
            }
    }

    private func textWidth(for width: CGFloat) -> CGFloat {
        max(40, width * zoom - (mode.horizontalPadding * 2))
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

// MARK: - Surface (Liquid Glass + fallback)

private struct CodeAgentsUITableSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else {
            content
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
                )
        }
    }
}

// MARK: - Layout

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

    static func columnAlignments(
        columns: [String],
        rows: [[String]]
    ) -> [TextAlignment] {
        columns.indices.map { index in
            rowsHaveNumericValues(rows: rows, columnIndex: index) ? .trailing : .leading
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
            return clamp(CGFloat(max(maxCharacters, title.count)) * 7.0 + 32, min: 64, max: 100)
        }

        if titleLowercased.contains("date")
            || titleLowercased.contains("expiry")
            || titleLowercased.contains("expires") {
            return mode == .preview ? 112 : 132
        }

        if titleLowercased.contains("feature")
            || titleLowercased.contains("description")
            || titleLowercased.contains("notes")
            || hasLongText {
            return mode == .preview ? 200 : 280
        }

        if index == 0 {
            return clamp(CGFloat(maxCharacters) * 6.8 + 40, min: 120, max: mode == .preview ? 180 : 240)
        }

        return clamp(CGFloat(maxCharacters) * 6.8 + 36, min: 96, max: mode == .preview ? 160 : 210)
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

// MARK: - Zoom / export

enum CodeAgentsUITableZoom: String, CaseIterable, Identifiable {
    case fit
    case normal
    case large
    case extraLarge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: return "Fit"
        case .normal: return "100%"
        case .large: return "125%"
        case .extraLarge: return "150%"
        }
    }

    var scale: CGFloat {
        switch self {
        case .fit, .normal: return 1
        case .large: return 1.25
        case .extraLarge: return 1.5
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
