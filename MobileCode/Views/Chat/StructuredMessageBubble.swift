//
//  StructuredMessageBubble.swift
//  CodeAgentsMobile
//
//  Structured (content-block) message bubble with copy/share actions.
//

import SwiftUI

struct StructuredMessageBubble: View {
    let message: Message
    let structuredMessages: [StructuredMessageContent]
    @State private var showActionButtons = false
    
    var body: some View {
        let isUser = message.role == MessageRole.user
        let bubbleBackground = isUser ? Color.accentColor : Color(.systemGray6)
        let bubbleTextColor: Color = isUser ? .white : .primary
        let bubbleBorderColor = Color(.systemGray4).opacity(0.6)
        let fallbackBlocks = message.fallbackContentBlocks()

        ZStack {
            // Invisible background to catch taps outside
            if showActionButtons {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showActionButtons = false
                        }
                    }
            }
            
            VStack(spacing: 8) {
                // Collect all content blocks from all messages
                let allBlocks = structuredMessages.compactMap { structured -> [ContentBlock]? in
                    if let messageContent = structured.message {
                        switch messageContent.content {
                        case .text(let text):
                            return [ContentBlock.text(TextBlock(type: "text", text: text))]
                        case .blocks(let blocks):
                            return blocks
                        }
                    }
                    return nil
                }.flatMap { $0 }

                let visibleBlocks = allBlocks.filter { block in
                    if case .unknown = block {
                        return false
                    }
                    return true
                }

                let renderBlocks = visibleBlocks.isEmpty ? fallbackBlocks : visibleBlocks
                
                if !renderBlocks.isEmpty {
                // Display each block as a separate bubble
                ForEach(Array(renderBlocks.enumerated()), id: \.offset) { index, block in
                    HStack {
                        if message.role == MessageRole.user {
                            Spacer()
                        }
                        
                        // Different styling for different block types
                        switch block {
                        case .text(let textBlock):
                            // Text blocks get the traditional bubble styling
                            TextBlockView(
                                textBlock: textBlock,
                                textColor: bubbleTextColor,
                                isAssistant: message.role == MessageRole.assistant
                            )
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(bubbleBackground)
                                .foregroundColor(bubbleTextColor)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(isUser ? .clear : bubbleBorderColor, lineWidth: 0.5)
                                )
                                .shadow(color: isUser ? Color.accentColor.opacity(0.15) : Color.black.opacity(0.08), radius: 2, y: 1)
                                .frame(maxWidth: UIScreen.main.bounds.width * 0.78, alignment: message.role == MessageRole.user ? .trailing : .leading)
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showActionButtons.toggle()
                                    }
                                }
                            
                        case .toolUse(_), .toolResult(_):
                            // Tool use and results get their own special styling
                            ContentBlockView(
                                block: block, 
                                textColor: .primary,
                                isAssistant: message.role == MessageRole.assistant
                            )
                            .frame(maxWidth: UIScreen.main.bounds.width * 0.9, alignment: .leading)
                        case .unknown:
                            EmptyView()
                        }
                        
                        if message.role == MessageRole.assistant && block.isTextBlock {
                            Spacer()
                        }
                    }
                }
                
                // Action buttons for the entire message
                if showActionButtons {
                    HStack {
                        if message.role == MessageRole.user {
                            Spacer()
                        }
                        
                        HStack(spacing: 12) {
                            Button(action: {
                                // Extract all text content for copying
                                let textContent = renderBlocks.compactMap { block -> String? in
                                    switch block {
                                    case .text(let textBlock):
                                        return textBlock.text
                                    default:
                                        return nil
                                    }
                                }.joined(separator: "\n")
                                
                                UIPasteboard.general.string = textContent.isEmpty ? message.content : textContent
                                // Haptic feedback
                                let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                                impactFeedback.impactOccurred()
                                
                                // Hide button after copying
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showActionButtons = false
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 14))
                                    Text("Copy")
                                        .font(.system(size: 14))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(.systemGray6))
                                .foregroundColor(.primary)
                                .clipShape(Capsule())
                            }
                            
                            Button(action: {
                                // Extract all text content for sharing
                                let textContent = renderBlocks.compactMap { block -> String? in
                                    switch block {
                                    case .text(let textBlock):
                                        return textBlock.text
                                    default:
                                        return nil
                                    }
                                }.joined(separator: "\n")
                                
                                let shareContent = textContent.isEmpty ? message.content : textContent
                                
                                // Share functionality
                                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                   let rootViewController = windowScene.windows.first?.rootViewController {
                                    let activityViewController = UIActivityViewController(
                                        activityItems: [shareContent],
                                        applicationActivities: nil
                                    )
                                    rootViewController.present(activityViewController, animated: true)
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 14))
                                    Text("Share...")
                                        .font(.system(size: 14))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(.systemGray6))
                                .foregroundColor(.primary)
                                .clipShape(Capsule())
                            }
                        }
                        
                        if message.role == MessageRole.assistant {
                            Spacer()
                        }
                    }
                    .transition(.opacity.combined(with: .scale))
                }
            } else {
                // Fallback to plain text if no blocks
                VStack(alignment: message.role == MessageRole.user ? .trailing : .leading, spacing: 8) {
                    HStack {
                        if message.role == MessageRole.user {
                            Spacer()
                        }
                        
                        Text(message.content)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(message.role == MessageRole.user ? Color.accentColor : Color(.systemGray5))
                            .foregroundColor(message.role == MessageRole.user ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .frame(maxWidth: UIScreen.main.bounds.width * 0.8, alignment: message.role == MessageRole.user ? .trailing : .leading)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showActionButtons.toggle()
                                }
                            }
                        
                        if message.role == MessageRole.assistant {
                            Spacer()
                        }
                    }
                    
                    // Action buttons for fallback case
                    if showActionButtons {
                        HStack(spacing: 12) {
                            Button(action: {
                                UIPasteboard.general.string = message.content
                                // Haptic feedback
                                let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                                impactFeedback.impactOccurred()
                                
                                // Hide button after copying
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showActionButtons = false
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 14))
                                    Text("Copy")
                                        .font(.system(size: 14))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(.systemGray6))
                                .foregroundColor(.primary)
                                .clipShape(Capsule())
                            }
                            
                            Button(action: {
                                // Share functionality
                                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                   let rootViewController = windowScene.windows.first?.rootViewController {
                                    let activityViewController = UIActivityViewController(
                                        activityItems: [message.content],
                                        applicationActivities: nil
                                    )
                                    rootViewController.present(activityViewController, animated: true)
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 14))
                                    Text("Share...")
                                        .font(.system(size: 14))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(.systemGray6))
                                .foregroundColor(.primary)
                                .clipShape(Capsule())
                            }
                        }
                        .transition(.opacity.combined(with: .scale))
                    }
                }
            }
            } // End of VStack
        } // End of ZStack
    }
}

// Helper extension to check block type
extension ContentBlock {
    var isTextBlock: Bool {
        switch self {
        case .text(_):
            return true
        case .unknown:
            return false
        default:
            return false
        }
    }
}
