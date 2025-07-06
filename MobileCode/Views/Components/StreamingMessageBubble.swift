//
//  StreamingMessageBubble.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-06.
//

import SwiftUI

struct StreamingMessageBubble: View {
    let message: Message
    let streamingBlocks: [StreamingBlock]
    
    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(streamingBlocks.enumerated()), id: \.offset) { index, block in
                HStack {
                    if message.role == MessageRole.user {
                        Spacer()
                    }
                    
                    // Different styling for different block types
                    switch block {
                    case .text(_):
                        // Text blocks get the traditional bubble styling
                        streamingBlockView(for: block)
                            .padding(16)
                            .background(message.role == MessageRole.user ? Color.blue : Color(.systemGray5))
                            .foregroundColor(message.role == MessageRole.user ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .frame(maxWidth: UIScreen.main.bounds.width * 0.8, alignment: message.role == MessageRole.user ? .trailing : .leading)
                        
                    case .toolUse(_, _, _), .toolResult(_, _, _):
                        // Tool use and results get their own special styling
                        streamingBlockView(for: block)
                            .frame(maxWidth: UIScreen.main.bounds.width * 0.9, alignment: .leading)
                        
                    case .system(_, _, _):
                        // System messages get full width
                        streamingBlockView(for: block)
                            .frame(maxWidth: .infinity)
                    }
                    
                    if message.role == MessageRole.assistant && block.isTextBlock {
                        Spacer()
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func streamingBlockView(for block: StreamingBlock) -> some View {
        switch block {
        case .text(let text):
            StreamingTextBlock(
                text: text,
                textColor: message.role == MessageRole.user ? .white : .primary
            )
            
        case .toolUse(let id, let name, let input):
            StreamingToolUseBlock(
                toolName: name,
                parameters: input
            )
            
        case .toolResult(let toolUseId, let isError, let content):
            StreamingToolResultBlock(
                toolUseId: toolUseId,
                isError: isError,
                content: content
            )
            
        case .system(let sessionId, let cwd, let model):
            StreamingSystemBlock(
                sessionId: sessionId,
                cwd: cwd,
                model: model
            )
        }
    }
}

// Helper extension to check block type
extension StreamingBlock {
    var isTextBlock: Bool {
        switch self {
        case .text(_):
            return true
        default:
            return false
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        StreamingMessageBubble(
            message: Message(
                content: "Testing",
                role: .assistant,
                projectId: nil
            ),
            streamingBlocks: [
                .text("I'll help you with that task."),
                .toolUse(id: "123", name: "TodoWrite", input: ["todos": []]),
                .toolResult(toolUseId: "123", isError: false, content: "Todos updated successfully")
            ]
        )
    }
    .padding()
}