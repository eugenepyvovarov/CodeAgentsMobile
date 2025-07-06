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
    
    init(text: String, textColor: Color = .primary) {
        self.text = text
        self.textColor = textColor
    }
    
    var body: some View {
        Text(attributedString)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
    
    private var attributedString: AttributedString {
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
    
    init(text: String, textColor: Color = .primary) {
        self.text = text
        self.textColor = textColor
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parseMarkdownBlocks(), id: \.id) { block in
                block.view(textColor: textColor)
            }
        }
    }
    
    private func parseMarkdownBlocks() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var currentCodeBlock: [String] = []
        var inCodeBlock = false
        var currentParagraph: [String] = []
        
        for line in lines {
            let lineStr = String(line)
            
            // Check for code block markers
            if lineStr.starts(with: "```") {
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
                    if !currentParagraph.isEmpty {
                        blocks.append(.paragraph(currentParagraph.joined(separator: "\n")))
                        currentParagraph = []
                    }
                    inCodeBlock = true
                }
                continue
            }
            
            if inCodeBlock {
                currentCodeBlock.append(lineStr)
            } else if lineStr.starts(with: "- ") {
                // Bullet point
                if !currentParagraph.isEmpty {
                    blocks.append(.paragraph(currentParagraph.joined(separator: "\n")))
                    currentParagraph = []
                }
                blocks.append(.bulletPoint(String(lineStr.dropFirst(2))))
            } else if lineStr.isEmpty {
                // Empty line - end current paragraph
                if !currentParagraph.isEmpty {
                    blocks.append(.paragraph(currentParagraph.joined(separator: "\n")))
                    currentParagraph = []
                }
            } else {
                currentParagraph.append(lineStr)
            }
        }
        
        // Flush any remaining content
        if !currentParagraph.isEmpty {
            blocks.append(.paragraph(currentParagraph.joined(separator: "\n")))
        }
        if !currentCodeBlock.isEmpty {
            blocks.append(.codeBlock(currentCodeBlock.joined(separator: "\n")))
        }
        
        return blocks
    }
}

private enum MarkdownBlock: Identifiable {
    case paragraph(String)
    case bulletPoint(String)
    case codeBlock(String)
    
    var id: String {
        switch self {
        case .paragraph(let text): return "p_\(text.prefix(20))"
        case .bulletPoint(let text): return "b_\(text.prefix(20))"
        case .codeBlock(let text): return "c_\(text.prefix(20))"
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