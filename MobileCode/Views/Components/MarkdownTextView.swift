//
//  MarkdownTextView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-05.
//

import SwiftUI
import UIKit

struct MarkdownTextView: View {
    let text: String
    let textColor: Color
    @State private var cachedAttributedString: AttributedString
    
    init(text: String, textColor: Color = .primary) {
        self.text = text
        self.textColor = textColor
        _cachedAttributedString = State(
            initialValue: MarkdownTextView.makeAttributedString(from: text, textColor: textColor)
        )
    }
    
    var body: some View {
        Text(cachedAttributedString)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: text) { _, newText in
                cachedAttributedString = MarkdownTextView.makeAttributedString(from: newText, textColor: textColor)
            }
    }
    
    private static func makeAttributedString(from text: String, textColor: Color) -> AttributedString {
        do {
            var attributed = try AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )
            
            // Apply base text color
            attributed.foregroundColor = textColor
            
            // Style code blocks - check for code styling
            if #available(iOS 15.0, *) {
                for run in attributed.runs {
                    // Check if this run has code formatting
                    if run.inlinePresentationIntent?.contains(.code) == true {
                        attributed[run.range].font = .system(.body, design: .monospaced)
                        attributed[run.range].backgroundColor = textColor == .white 
                            ? Color.white.opacity(0.1) 
                            : Color.gray.opacity(0.1)
                        attributed[run.range].foregroundColor = textColor
                    }
                }
            }
            
            return attributed
        } catch {
            // Fallback to plain text if markdown parsing fails
            return AttributedString(text)
        }
    }
}

// Alternative implementation for multi-line markdown with better formatting
struct FullMarkdownTextView: View {
    let text: String
    let textColor: Color
    @State private var blocks: [MarkdownBlock]
    
    init(text: String, textColor: Color = .primary) {
        self.text = text
        self.textColor = textColor
        _blocks = State(initialValue: FullMarkdownTextView.parseMarkdownBlocks(from: text))
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                block.view(textColor: textColor)
            }
        }
        .onChange(of: text) { _, newText in
            blocks = FullMarkdownTextView.parseMarkdownBlocks(from: newText)
        }
    }
    
    private static func parseMarkdownBlocks(from text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var currentCodeBlock: [String] = []
        var inCodeBlock = false
        var currentParagraph: [String] = []

        func flushParagraph() {
            if !currentParagraph.isEmpty {
                blocks.append(.paragraph(currentParagraph.joined(separator: "\n")))
                currentParagraph = []
            }
        }
        
        var index = 0
        while index < lines.count {
            let lineStr = lines[index]
            let trimmed = lineStr.trimmingCharacters(in: .whitespaces)
            
            // Check for code block markers
            if trimmed.starts(with: "```") {
                if inCodeBlock {
                    // End code block
                    if !currentCodeBlock.isEmpty {
                        blocks.append(.codeBlock(currentCodeBlock.joined(separator: "\n")))
                        currentCodeBlock = []
                    }
                    inCodeBlock = false
                } else {
                    // Start code block
                    // First, flush any pending paragraph
                    flushParagraph()
                    inCodeBlock = true
                }
                index += 1
                continue
            }
            
            if inCodeBlock {
                currentCodeBlock.append(lineStr)
                index += 1
                continue
            }

            if let table = parseMarkdownTable(from: lines, startingAt: index) {
                flushParagraph()
                blocks.append(.table(headers: table.headers, alignments: table.alignments, rows: table.rows))
                index = table.nextIndex
                continue
            }

            if let headingBlock = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(headingBlock)
            } else if let numberedBlock = parseNumberedItem(trimmed) {
                flushParagraph()
                blocks.append(numberedBlock)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                // Bullet point
                flushParagraph()
                blocks.append(.bulletPoint(String(trimmed.dropFirst(2))))
            } else if trimmed.isEmpty {
                // Empty line - end current paragraph
                flushParagraph()
            } else {
                currentParagraph.append(lineStr)
            }

            index += 1
        }
        
        // Flush any remaining content
        flushParagraph()
        if !currentCodeBlock.isEmpty {
            blocks.append(.codeBlock(currentCodeBlock.joined(separator: "\n")))
        }
        
        return blocks
    }

    private static func parseMarkdownTable(
        from lines: [String],
        startingAt startIndex: Int
    ) -> (headers: [String], alignments: [MarkdownTableAlignment], rows: [[String]], nextIndex: Int)? {
        guard startIndex + 1 < lines.count else { return nil }

        let headerLine = lines[startIndex]
        let separatorLine = lines[startIndex + 1]

        let headerTrimmed = headerLine.trimmingCharacters(in: .whitespaces)
        let separatorTrimmed = separatorLine.trimmingCharacters(in: .whitespaces)

        guard headerTrimmed.contains("|"), separatorTrimmed.contains("|") else { return nil }

        let headers = parseMarkdownTableRowCells(headerLine)
        guard !headers.isEmpty else { return nil }

        guard let alignments = parseMarkdownTableSeparatorAlignments(separatorLine) else { return nil }

        var rows: [[String]] = []
        var index = startIndex + 2

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { break }
            guard trimmed.contains("|") else { break }
            if trimmed.starts(with: "```") { break }

            rows.append(parseMarkdownTableRowCells(line))
            index += 1
        }

        return (headers: headers, alignments: alignments, rows: rows, nextIndex: index)
    }

    private static func parseMarkdownTableRowCells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") {
            row.removeFirst()
        }
        if row.hasSuffix("|") {
            row.removeLast()
        }

        return row
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    private static func parseMarkdownTableSeparatorAlignments(_ line: String) -> [MarkdownTableAlignment]? {
        let rawCells = parseMarkdownTableRowCells(line)
        guard !rawCells.isEmpty else { return nil }

        var alignments: [MarkdownTableAlignment] = []
        alignments.reserveCapacity(rawCells.count)

        for rawCell in rawCells {
            let cleaned = rawCell.filter { !$0.isWhitespace }
            guard cleaned.count >= 3 else { return nil }

            let hasLeadingColon = cleaned.hasPrefix(":")
            let hasTrailingColon = cleaned.hasSuffix(":")

            var core = cleaned
            if hasLeadingColon {
                core.removeFirst()
            }
            if hasTrailingColon {
                core.removeLast()
            }

            guard core.count >= 3, core.allSatisfy({ $0 == "-" }) else { return nil }

            if hasLeadingColon && hasTrailingColon {
                alignments.append(.center)
            } else if hasTrailingColon {
                alignments.append(.trailing)
            } else {
                alignments.append(.leading)
            }
        }

        return alignments
    }
}

private enum MarkdownTableAlignment: Hashable {
    case leading
    case center
    case trailing
}

private enum MarkdownBlock: Identifiable {
    case paragraph(String)
    case bulletPoint(String)
    case numberedItem(Int, String)
    case heading(Int, String)
    case codeBlock(String)
    case table(headers: [String], alignments: [MarkdownTableAlignment], rows: [[String]])
    
    var id: String {
        switch self {
        case .paragraph(let text): return "p_\(text.hashValue)"
        case .bulletPoint(let text): return "b_\(text.hashValue)"
        case .numberedItem(let index, let text): return "n_\(index)_\(text.hashValue)"
        case .heading(let level, let text): return "h\(level)_\(text.hashValue)"
        case .codeBlock(let text): return "c_\(text.hashValue)"
        case .table(let headers, let alignments, let rows):
            return "t_\(headers.hashValue)_\(alignments.hashValue)_\(rows.hashValue)"
        }
    }
    
    @ViewBuilder
    func view(textColor: Color) -> some View {
        switch self {
        case .paragraph(let text):
            MarkdownTextView(text: text, textColor: textColor)
        
        case .bulletPoint(let text):
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .foregroundColor(textColor)
                MarkdownTextView(text: text, textColor: textColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .numberedItem(let index, let text):
            HStack(alignment: .top, spacing: 8) {
                Text("\(index).")
                    .foregroundColor(textColor)
                MarkdownTextView(text: text, textColor: textColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .heading(let level, let text):
            MarkdownTextView(text: text, textColor: textColor)
                .font(headingFont(for: level))
                .padding(.top, 4)
            
        case .codeBlock(let code):
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(textColor)
                .padding(8)
                .background(textColor == .white 
                    ? Color.white.opacity(0.1) 
                    : Color.gray.opacity(0.1))
                .cornerRadius(8)
                .textSelection(.enabled)

        case .table(let headers, let alignments, let rows):
            MarkdownTableView(headers: headers, alignments: alignments, rows: rows, textColor: textColor)
        }
    }
}

private struct MarkdownTableView: View {
    let headers: [String]
    let alignments: [MarkdownTableAlignment]
    let rows: [[String]]
    let textColor: Color

    var body: some View {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        if columnCount == 0 {
            EmptyView()
        } else {
            let borderColor = textColor == .white ? Color.white.opacity(0.25) : Color(.systemGray4).opacity(0.6)
            let headerBackground = textColor == .white ? Color.white.opacity(0.12) : Color(.systemGray5).opacity(0.7)
            let stripeBackground = textColor == .white ? Color.white.opacity(0.06) : Color(.systemGray5).opacity(0.35)
            let columnWidth = preferredColumnWidth(columnCount: columnCount)

            ScrollView(.horizontal, showsIndicators: false) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { columnIndex in
                            MarkdownTextView(text: cellText(for: headers, at: columnIndex), textColor: textColor)
                                .font(.subheadline.weight(.semibold))
                                .padding(.vertical, 8)
                                .padding(.horizontal, 10)
                                .frame(width: columnWidth, alignment: frameAlignment(for: alignment(at: columnIndex)))
                                .background(headerBackground)
                                .overlay(
                                    Rectangle().stroke(borderColor, lineWidth: 0.5)
                                )
                        }
                    }

                    ForEach(0..<rows.count, id: \.self) { rowIndex in
                        let row = rows[rowIndex]
                        GridRow {
                            ForEach(0..<columnCount, id: \.self) { columnIndex in
                                MarkdownTextView(text: cellText(for: row, at: columnIndex), textColor: textColor)
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 10)
                                    .frame(width: columnWidth, alignment: frameAlignment(for: alignment(at: columnIndex)))
                                    .background(rowIndex.isMultiple(of: 2) ? Color.clear : stripeBackground)
                                    .overlay(
                                        Rectangle().stroke(borderColor, lineWidth: 0.5)
                                    )
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

    private func cellText(for cells: [String], at index: Int) -> String {
        guard index < cells.count else { return "" }
        return cells[index]
    }

    private func alignment(at index: Int) -> MarkdownTableAlignment {
        guard index < alignments.count else { return .leading }
        return alignments[index]
    }

    private func frameAlignment(for alignment: MarkdownTableAlignment) -> Alignment {
        switch alignment {
        case .leading:
            return .leading
        case .center:
            return .center
        case .trailing:
            return .trailing
        }
    }

    private func preferredColumnWidth(columnCount: Int) -> CGFloat {
        let minimumColumnWidth: CGFloat = 90
        let maximumColumnWidth: CGFloat = 240

        let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        let headerBaseFont = UIFont.preferredFont(forTextStyle: .subheadline)
        let headerFont = UIFont.systemFont(ofSize: headerBaseFont.pointSize, weight: .semibold)

        var maxContentWidth: CGFloat = 0
        for columnIndex in 0..<columnCount {
            maxContentWidth = max(maxContentWidth, maxContentWidthForColumn(columnIndex, headerFont: headerFont, bodyFont: bodyFont))
        }

        let paddedWidth = ceil(maxContentWidth + 20)
        return min(maximumColumnWidth, max(minimumColumnWidth, paddedWidth))
    }

    private func maxContentWidthForColumn(_ columnIndex: Int, headerFont: UIFont, bodyFont: UIFont) -> CGFloat {
        var maxWidth = measuredTextWidth(cellText(for: headers, at: columnIndex), font: headerFont)

        for row in rows {
            maxWidth = max(maxWidth, measuredTextWidth(cellText(for: row, at: columnIndex), font: bodyFont))
        }

        return maxWidth
    }

    private func measuredTextWidth(_ text: String, font: UIFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return (text as NSString).size(withAttributes: [.font: font]).width
    }
}

private func parseHeading(_ trimmedLine: String) -> MarkdownBlock? {
    guard trimmedLine.hasPrefix("#") else { return nil }
    let prefixCount = trimmedLine.prefix { $0 == "#" }.count
    guard prefixCount > 0 && prefixCount <= 6 else { return nil }
    let text = trimmedLine.dropFirst(prefixCount).trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    return .heading(prefixCount, String(text))
}

private func parseNumberedItem(_ trimmedLine: String) -> MarkdownBlock? {
    guard let dotIndex = trimmedLine.firstIndex(of: ".") else { return nil }
    let numberPart = trimmedLine[..<dotIndex]
    guard !numberPart.isEmpty, numberPart.allSatisfy({ $0.isNumber }) else { return nil }
    let remainderIndex = trimmedLine.index(after: dotIndex)
    guard remainderIndex < trimmedLine.endIndex else { return nil }
    let remainder = trimmedLine[remainderIndex...]
    guard remainder.first == " " else { return nil }
    let text = remainder.dropFirst().trimmingCharacters(in: .whitespaces)
    guard let number = Int(numberPart), !text.isEmpty else { return nil }
    return .numberedItem(number, String(text))
}

private func headingFont(for level: Int) -> Font {
    switch level {
    case 1:
        return .title3.weight(.semibold)
    case 2:
        return .headline
    case 3:
        return .subheadline.weight(.semibold)
    default:
        return .subheadline
    }
}
