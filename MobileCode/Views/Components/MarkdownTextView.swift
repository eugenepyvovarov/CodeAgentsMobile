//
//  MarkdownTextView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-05.
//

import SwiftUI

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
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var currentCodeBlock: [String] = []
        var inCodeBlock = false
        var currentParagraph: [String] = []

        func flushParagraph() {
            if !currentParagraph.isEmpty {
                blocks.append(.paragraph(currentParagraph.joined(separator: "\n")))
                currentParagraph = []
            }
        }
        
        for line in lines {
            let lineStr = String(line)
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
                continue
            }
            
            if inCodeBlock {
                currentCodeBlock.append(lineStr)
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
        }
        
        // Flush any remaining content
        flushParagraph()
        if !currentCodeBlock.isEmpty {
            blocks.append(.codeBlock(currentCodeBlock.joined(separator: "\n")))
        }
        
        return blocks
    }
}

private enum MarkdownBlock: Identifiable {
    case paragraph(String)
    case bulletPoint(String)
    case numberedItem(Int, String)
    case heading(Int, String)
    case codeBlock(String)
    
    var id: String {
        switch self {
        case .paragraph(let text): return "p_\(text.hashValue)"
        case .bulletPoint(let text): return "b_\(text.hashValue)"
        case .numberedItem(let index, let text): return "n_\(index)_\(text.hashValue)"
        case .heading(let level, let text): return "h\(level)_\(text.hashValue)"
        case .codeBlock(let text): return "c_\(text.hashValue)"
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
        }
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
