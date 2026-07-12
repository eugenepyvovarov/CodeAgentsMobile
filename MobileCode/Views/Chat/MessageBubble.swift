//
//  MessageBubble.swift
//  CodeAgentsMobile
//
//  Chat message bubble shell (labels, timestamps, routing to plain/structured content).
//

import SwiftUI

struct MessageBubble: View {
    let message: Message
    let userLabel: String
    let isStreaming: Bool
    let streamingBlocks: [ContentBlock]
    var onRetryAttachmentUpload: (() -> Void)? = nil
    
    var body: some View {
        // Check if message has visible content
        let hasStructuredContent = (message.structuredMessages?.isEmpty == false) || 
                                 (message.structuredContent != nil)
        let hasVisibleContent = !message.content.isEmpty ||
                              message.hasChatAttachments ||
                              hasStructuredContent || 
                              isStreaming
        let isUser = message.role == MessageRole.user
        let isLocalError = message.presentsAsLocalError
        
        if hasVisibleContent {
            if isLocalError {
                // Centered orange error banner — not an assistant chat bubble.
                VStack(spacing: 4) {
                    ChatErrorBannerView(text: message.content)
                    Text(DateFormatter.smartFormat(message.timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .accessibilityIdentifier("chat-message-error-\(message.id.uuidString)")
            } else {
                VStack(spacing: 4) {
                    // Sender label only for user turns ("You"). Agent name lives in the chat header.
                    if isUser {
                        HStack(spacing: 6) {
                            Spacer()
                            Text(userLabel)
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                    // Message content
                    messageContent
                    
                    // Timestamp
                    HStack {
                        if message.role == MessageRole.user {
                            Spacer()
                        }
                        
                        Text(DateFormatter.smartFormat(message.timestamp))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                        
                        if message.role == MessageRole.assistant {
                            Spacer()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: message.role == MessageRole.user ? .trailing : .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                .accessibilityIdentifier("chat-message-\(message.role == MessageRole.user ? "user" : "assistant")-\(message.id.uuidString)")
            }
        }
    }
    
    @ViewBuilder
    private var messageContent: some View {
        let fallbackBlocks = message.fallbackContentBlocks()
        if isStreaming {
            if !streamingBlocks.isEmpty {
                VStack(spacing: 8) {
                    streamingBlocksView
                }
            } else if !message.content.isEmpty {
                PlainMessageBubble(message: message, onRetryAttachmentUpload: onRetryAttachmentUpload)
            } else {
                StreamingPlaceholderBubble(isUser: message.role == MessageRole.user)
            }
        } else if let messages = message.structuredMessages, !messages.isEmpty {
            structuredMessageStack(messages)
        } else if let structured = message.structuredContent {
            structuredMessageStack([structured])
        } else if !fallbackBlocks.isEmpty {
            structuredMessageStack([])
        } else {
            PlainMessageBubble(message: message, onRetryAttachmentUpload: onRetryAttachmentUpload)
        }
    }

    @ViewBuilder
    private var streamingBlocksView: some View {
        VStack(spacing: 8) {
            ForEach(0..<streamingBlocks.count, id: \.self) { index in
                let block = streamingBlocks[index]
                HStack {
                    if message.role == MessageRole.user {
                        Spacer()
                    }
                    
                    switch block {
                    case .text(let textBlock):
                        TextBlockView(
                            textBlock: textBlock,
                            textColor: message.role == MessageRole.user ? .white : .primary,
                            isStreaming: true,
                            isAssistant: message.role == MessageRole.assistant
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(message.role == MessageRole.user ? Color.accentColor : Color(.systemGray5))
                        .foregroundColor(message.role == MessageRole.user ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .frame(maxWidth: UIScreen.main.bounds.width * 0.8, alignment: message.role == MessageRole.user ? .trailing : .leading)
                        .transition(.opacity)
                        .animation(.easeIn(duration: 0.2), value: streamingBlocks.count)
                        
                    case .toolUse(_), .toolResult(_):
                        ContentBlockView(
                            block: block,
                            textColor: .primary,
                            isStreaming: true,
                            isAssistant: message.role == MessageRole.assistant
                        )
                        .frame(maxWidth: UIScreen.main.bounds.width * 0.9, alignment: .leading)
                        .transition(.opacity)
                        .animation(.easeIn(duration: 0.2), value: streamingBlocks.count)
                    case .unknown:
                        EmptyView()
                    }
                    
                    if message.role == MessageRole.assistant && block.isTextBlock {
                        Spacer()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func structuredMessageStack(_ messages: [StructuredMessageContent]) -> some View {
        let systemMessages = messages.filter { $0.type == "system" && !isSessionInfoSystemMessage($0) }
        let contentMessages = messages.filter { shouldRenderContentMessage($0) }
        let fallbackBlocks = message.fallbackContentBlocks()
        
        VStack(spacing: 8) {
            ForEach(Array(systemMessages.enumerated()), id: \.offset) { _, msg in
                SystemMessageView(message: msg)
            }
            
            if !contentMessages.isEmpty || !fallbackBlocks.isEmpty {
                StructuredMessageBubble(message: message, structuredMessages: contentMessages)
            }
        }
    }

    private func shouldRenderContentMessage(_ message: StructuredMessageContent) -> Bool {
        switch message.type {
        case "assistant":
            return hasRenderableContent(message)
        case "user":
            return hasRenderableContent(message)
        default:
            return false
        }
    }

    private func isSessionInfoSystemMessage(_ message: StructuredMessageContent) -> Bool {
        guard message.type == "system" else { return false }
        if let subtype = message.subtype?.lowercased(), subtype.contains("session") {
            return true
        }
        if let data = message.data, !data.isEmpty {
            return true
        }
        return true
    }

    private func hasRenderableContent(_ message: StructuredMessageContent) -> Bool {
        guard let content = message.message else { return false }
        switch content.content {
        case .blocks(let blocks):
            return blocks.contains { block in
                switch block {
                case .text(let textBlock):
                    return !textBlock.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .toolUse(let toolUseBlock):
                    return !BlockFormattingUtils.isBlockedToolName(toolUseBlock.name)
                case .toolResult(let toolResultBlock):
                    return !BlockFormattingUtils.isBlockedToolResultContent(toolResultBlock.content)
                case .unknown:
                    return false
                }
            }
        case .text(let text):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func containsToolResult(_ message: StructuredMessageContent) -> Bool {
        guard let content = message.message else { return false }
        switch content.content {
        case .blocks(let blocks):
            return blocks.contains { block in
                if case .toolResult = block {
                    return true
                }
                return false
            }
        case .text:
            return false
        }
    }
}
