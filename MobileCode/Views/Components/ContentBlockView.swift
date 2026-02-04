//
//  ContentBlockView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-05.
//

import SwiftUI

struct ContentBlockView: View {
    let block: ContentBlock
    let textColor: Color
    let isStreaming: Bool
    let isAssistant: Bool
    @State private var isExpanded: Bool = false
    
    init(
        block: ContentBlock,
        textColor: Color = .primary,
        isStreaming: Bool = false,
        isAssistant: Bool = false
    ) {
        self.block = block
        self.textColor = textColor
        self.isStreaming = isStreaming
        self.isAssistant = isAssistant
    }
    
    var body: some View {
        switch block {
        case .text(let textBlock):
            TextBlockView(
                textBlock: textBlock,
                textColor: textColor,
                isStreaming: isStreaming,
                isAssistant: isAssistant
            )
            
        case .toolUse(let toolUseBlock):
            if BlockFormattingUtils.isBlockedToolName(toolUseBlock.name) {
                EmptyView()
            } else {
                ToolUseView(toolUseBlock: toolUseBlock, isStreaming: isStreaming)
            }
            
        case .toolResult(let toolResultBlock):
            if BlockFormattingUtils.isBlockedToolResultContent(toolResultBlock.content) {
                EmptyView()
            } else {
                ToolResultView(
                    toolResultBlock: toolResultBlock,
                    isExpanded: $isExpanded
                )
            }
            
        case .unknown:
            EmptyView()
        }
    }
}
