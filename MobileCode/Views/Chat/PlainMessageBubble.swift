//
//  PlainMessageBubble.swift
//  CodeAgentsMobile
//
//  Simple text message bubble with copy/share actions.
//

import SwiftUI

struct PlainMessageBubble: View {
    let message: Message
    @State private var showActionButtons = false
    
    var body: some View {
        let isUser = message.role == MessageRole.user
        let bubbleBackground = isUser ? Color.accentColor : Color(.systemGray6)
        let bubbleTextColor: Color = isUser ? .white : .primary
        let bubbleBorderColor = Color(.systemGray4).opacity(0.6)
        let lowercasedContent = message.content.lowercased()
        let containsCodeAgentsUI = lowercasedContent.contains("codeagents_ui")
            && lowercasedContent.contains("```")
        let compactContent = lowercasedContent.filter { !$0.isWhitespace }
        let containsTableWidget = containsCodeAgentsUI && compactContent.contains("\"type\":\"table\"")
        let bubbleMaxWidth = UIScreen.main.bounds.width * (containsTableWidget ? 0.94 : 0.78)
        let shouldForceFullWidth = !isUser && containsCodeAgentsUI

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
            
            HStack {
                if message.role == MessageRole.user {
                    Spacer()
                }
                
                VStack(alignment: message.role == MessageRole.user ? .trailing : .leading, spacing: 8) {
                    CodeAgentsUIMessageContentView(
                        text: message.content,
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
                        .frame(
                            minWidth: shouldForceFullWidth ? bubbleMaxWidth : nil,
                            maxWidth: bubbleMaxWidth,
                            alignment: isUser ? .trailing : .leading
                        )
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showActionButtons.toggle()
                            }
                        }
                    
                    // Action buttons (same style for both user and assistant)
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
                
                if message.role == MessageRole.assistant {
                    Spacer()
                }
            }
        }
    }
}
