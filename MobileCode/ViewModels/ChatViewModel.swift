//
//  ChatViewModel.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//
//  Purpose: Manages chat state and message handling
//  - Stores chat messages
//  - Handles sending/receiving messages
//  - Will integrate with ClaudeCodeService later
//

import SwiftUI
import Observation

/// ViewModel for the chat interface
/// Integrates with ClaudeCodeService for real Claude interactions
@MainActor
@Observable
class ChatViewModel {
    // MARK: - Properties
    
    /// All messages in the current chat session
    var messages: [Message] = []
    
    /// Whether we're currently processing a message
    var isProcessing = false
    
    /// Show/hide attachment options
    var showAttachments = false
    
    /// Current assistant message being streamed
    var streamingMessage: Message?
    
    /// Claude Code service reference
    @MainActor
    private var claudeService: ClaudeCodeService {
        ClaudeCodeService.shared
    }
    
    /// Current project context from ProjectContext manager
    @MainActor
    var currentProject: Project? {
        ProjectContext.shared.activeProject
    }
    
    // MARK: - Initialization
    
    init() {
        // No mock messages - start with empty conversation
    }
    
    // MARK: - Methods
    
    /// Send a message to Claude
    /// - Parameter text: The message text
    /// - Note: Uses ClaudeCodeService for streaming responses
    func sendMessage(_ text: String) async {
        // Add user message
        let userMessage = Message(content: text, role: .user)
        
        await MainActor.run {
            messages.append(userMessage)
            isProcessing = true
        }
        
        // Get active project
        guard let project = currentProject else {
            let errorMessage = Message(
                content: "No active project. Please select a project first.",
                role: .assistant
            )
            await MainActor.run {
                messages.append(errorMessage)
                isProcessing = false
            }
            return
        }
        
        // Create assistant message for streaming
        let assistantMessage = Message(content: "", role: .assistant)
        await MainActor.run {
            messages.append(assistantMessage)
            streamingMessage = assistantMessage
        }
        
        // Get streaming response from Claude
        let stream = claudeService.sendMessage(text, in: project)
        
        do {
            var fullContent = ""
            
            for try await chunk in stream {
                if chunk.isError {
                    // Handle error chunks
                    fullContent = chunk.content
                    break
                } else if !chunk.isComplete {
                    // Append content chunks
                    fullContent += chunk.content
                    
                    // Update the message content on main thread
                    await MainActor.run {
                        if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
                            messages[index].content = fullContent
                        }
                    }
                }
            }
            
            // Finalize the message
            await MainActor.run {
                if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
                    // Only update if we have content, otherwise keep what we have
                    if !fullContent.isEmpty {
                        messages[index].content = fullContent
                    }
                }
                streamingMessage = nil
                isProcessing = false
            }
            
        } catch {
            // Handle streaming errors
            let errorContent = "Failed to get response: \(error.localizedDescription)"
            await MainActor.run {
                if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
                    messages[index].content = errorContent
                }
                streamingMessage = nil
                isProcessing = false
            }
        }
    }
    
    /// Clear all messages and start fresh
    @MainActor
    func clearChat() {
        messages.removeAll()
        claudeService.clearSessions()
    }
    
    /// Check Claude installation and authentication status
    func checkClaudeStatus(on server: Server) async -> (installed: Bool, authenticated: Bool, error: String?) {
        return await claudeService.checkClaudeStatus(on: server)
    }
    
    /// Attach a file to the conversation
    /// - Parameter fileURL: URL of the file to attach
    func attachFile(_ fileURL: URL) {
        // TODO: Implement file attachment when we have file access
        print("File attachment not yet implemented: \(fileURL)")
    }
    
}