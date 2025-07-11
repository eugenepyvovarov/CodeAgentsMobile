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
    @State private var isExpanded: Bool = false
    
    init(block: ContentBlock, textColor: Color = .primary, isStreaming: Bool = false) {
        self.block = block
        self.textColor = textColor
        self.isStreaming = isStreaming
    }
    
    var body: some View {
        switch block {
        case .text(let textBlock):
            TextBlockView(textBlock: textBlock, textColor: textColor, isStreaming: isStreaming)
            
        case .toolUse(let toolUseBlock):
            ToolUseView(toolUseBlock: toolUseBlock, isStreaming: isStreaming)
            
        case .toolResult(let toolResultBlock):
            ToolResultView(
                toolResultBlock: toolResultBlock,
                isExpanded: $isExpanded
            )
            .onAppear {
                // Auto-expand errors
                if toolResultBlock.isError {
                    isExpanded = true
                }
            }
        }
    }
}