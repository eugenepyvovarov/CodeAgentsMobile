//
//  CodeAgentsUIMessageContentView.swift
//  CodeAgentsMobile
//
//  Purpose: Render assistant message text with embedded codeagents_ui blocks.
//

import SwiftUI

struct CodeAgentsUIMessageContentView: View {
    let text: String
    let textColor: Color
    let isAssistant: Bool

    var body: some View {
        if isAssistant {
            let segments = CodeAgentsUIBlockExtractor.segments(from: text)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .markdown(let markdown):
                        if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            FullMarkdownTextView(text: markdown, textColor: textColor)
                        }
                    case .ui(let block):
                        CodeAgentsUIRendererView(block: block, project: nil)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            FullMarkdownTextView(text: text, textColor: textColor)
        }
    }
}
