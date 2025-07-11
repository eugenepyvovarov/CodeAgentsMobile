//
//  ChatViewModel.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//
//  Purpose: Manages chat state and message handling
//  - Stores chat messages
//  - Handles sending/receiving messages
//  - Integrates with ClaudeCodeService
//

import SwiftUI
import Observation
import SwiftData


/// ViewModel for the chat interface
/// Handles message display, streaming, and persistence
@MainActor
@Observable
class ChatViewModel {
    // MARK: - Properties
    
    /// All messages in the current chat session
    var messages: [Message] = []
    
    /// Whether we're currently processing a message
    var isProcessing = false
    
    /// Current assistant message being streamed
    var streamingMessage: Message?
    
    /// Current streaming blocks being displayed
    var streamingBlocks: [ContentBlock] = []
    
    /// Model context for persistence
    private var modelContext: ModelContext?
    
    /// Current project ID
    private var projectId: UUID?
    
    /// Claude Code service reference
    private let claudeService = ClaudeCodeService.shared
    
    // MARK: - Configuration
    
    /// Configure the view model with model context and project
    func configure(modelContext: ModelContext, projectId: UUID) {
        self.modelContext = modelContext
        self.projectId = projectId
        loadMessages()
        
        // Check Claude installation when configuring
        Task {
            if let server = ProjectContext.shared.activeServer {
                await claudeService.checkClaudeInstallation(for: server)
            }
        }
    }
    
    // MARK: - Public Methods
    
    /// Send a message to Claude
    /// - Parameter text: The message text
    func sendMessage(_ text: String) async {
        guard let project = ProjectContext.shared.activeProject else {
            await addErrorMessage("No active project. Please select a project first.")
            return
        }
        
        // Check if Claude is installed
        if let server = ProjectContext.shared.activeServer,
           let isInstalled = claudeService.claudeInstallationStatus[server.id],
           !isInstalled {
            await addErrorMessage("Claude CLI is not installed on this server. Please install it first.")
            return
        }
        
        // Create and save user message
        let userMessage = createMessage(content: text, role: .user)
        
        // Create placeholder for assistant response
        let assistantMessage = createMessage(content: "", role: .assistant)
        streamingMessage = assistantMessage
        isProcessing = true
        
        // Stream response from Claude
        do {
            let stream = claudeService.sendMessage(text, in: project)
            var fullContent = ""
            var jsonMessages: [String] = []
            self.streamingBlocks = [] // Clear previous streaming blocks
            var hasReceivedContent = false
            
            for try await chunk in stream {
                if chunk.isError {
                    print("🔴 Error chunk received: \(chunk.content)")
                    
                    // Extract error message from metadata if available
                    var errorText = chunk.content
                    
                    // Check metadata for more detailed error information
                    if errorText.isEmpty {
                        if let type = chunk.metadata?["type"] as? String {
                            if type == "assistant" {
                                // Look for error in content blocks
                                if let content = chunk.metadata?["content"] as? [[String: Any]] {
                                    for block in content {
                                        if let blockType = block["type"] as? String,
                                           blockType == "text",
                                           let text = block["text"] as? String {
                                            errorText = text
                                            break
                                        }
                                    }
                                }
                            } else if type == "result" {
                                // Look for error in result field
                                if let result = chunk.metadata?["result"] as? String {
                                    errorText = result
                                }
                            }
                        }
                    }
                    
                    // If still empty, provide a default message
                    if errorText.isEmpty {
                        errorText = """
                        Authentication failed. Please check:
                        1. Your API key or token in Settings
                        2. Claude CLI is installed on the server
                        3. Network connection to the server
                        """
                    }
                    
                    fullContent = errorText
                    streamingBlocks = [.text(TextBlock(type: "text", text: fullContent))]
                    
                    // Create a proper error message structure
                    let errorMessage: [String: Any] = [
                        "type": "assistant",
                        "message": [
                            "id": UUID().uuidString,
                            "role": "assistant",
                            "content": [
                                [
                                    "type": "text",
                                    "text": fullContent
                                ]
                            ]
                        ]
                    ]
                    
                    // Add to jsonMessages so it gets properly saved
                    if let jsonString = try? JSONSerialization.data(withJSONObject: errorMessage, options: []),
                       let stringData = String(data: jsonString, encoding: .utf8) {
                        jsonMessages.append(stringData)
                    }
                    
                    hasReceivedContent = true
                    break
                }
                
                // Extract original JSON from metadata
                if let originalJSON = chunk.metadata?["originalJSON"] as? String {
                    jsonMessages.append(originalJSON)
                    
                    // Update the message's originalJSON during streaming for proper rendering
                    let currentJsonData = jsonMessages.joined(separator: "\n").data(using: .utf8)
                    updateMessageWithJSON(assistantMessage, content: fullContent, originalJSON: currentJsonData)
                }
                
                // Process content based on message type
                if let type = chunk.metadata?["type"] as? String {
                    switch type {
                    case "assistant":
                        hasReceivedContent = true
                        
                        // Parse blocks and create streaming views
                        if let blocks = chunk.metadata?["content"] as? [[String: Any]] {
                            // Process blocks from JSON - this represents the complete state
                            var accumulatedBlocks: [ContentBlock] = []
                            var activeTextBlock: TextBlock? = nil
                            var processedToolIds = Set<String>()
                            
                            // First, preserve any tool results we already have
                            for existingBlock in streamingBlocks {
                                if case .toolResult(let toolResult) = existingBlock {
                                    accumulatedBlocks.append(existingBlock)
                                    processedToolIds.insert(toolResult.toolUseId)
                                }
                            }
                            
                            // Process new blocks from the stream
                            for block in blocks {
                                if let blockType = block["type"] as? String {
                                    switch blockType {
                                    case "text":
                                        if let text = block["text"] as? String {
                                            // For text blocks, we always use the latest version
                                            // since text can be incrementally built
                                            activeTextBlock = TextBlock(type: "text", text: text)
                                            // Update fullContent with the latest text
                                            fullContent = text
                                        }
                                    case "tool_use":
                                        if let name = block["name"] as? String,
                                           let id = block["id"] as? String {
                                            // Only add tool use if we don't already have its result
                                            if !processedToolIds.contains(id) {
                                                let input = block["input"] as? [String: Any] ?? [:]
                                                accumulatedBlocks.append(.toolUse(ToolUseBlock(
                                                    type: "tool_use",
                                                    id: id,
                                                    name: name,
                                                    input: input
                                                )))
                                            }
                                        }
                                    default:
                                        break
                                    }
                                }
                            }
                            
                            // Add the active text block at the beginning if it exists
                            if let textBlock = activeTextBlock {
                                accumulatedBlocks.insert(.text(textBlock), at: 0)
                            }
                            
                            streamingBlocks = accumulatedBlocks
                            updateStreamingMessage(assistantMessage, blocks: streamingBlocks)
                        }
                        
                    case "user":
                        // Handle tool results during streaming
                        if let blocks = chunk.metadata?["content"] as? [[String: Any]] {
                            // Build new complete list including tool results
                            var updatedBlocks = streamingBlocks
                            
                            for block in blocks {
                                if let blockType = block["type"] as? String,
                                   blockType == "tool_result",
                                   let toolUseId = block["tool_use_id"] as? String {
                                    let isError = block["is_error"] as? Bool ?? false
                                    let content = block["content"] as? String ?? ""
                                    
                                    // Find and replace the matching tool use with its result
                                    for (index, existingBlock) in updatedBlocks.enumerated() {
                                        switch existingBlock {
                                        case .toolUse(let toolUseBlock):
                                            if toolUseBlock.id == toolUseId {
                                                // Replace tool use with tool result
                                                updatedBlocks[index] = .toolResult(createToolResultBlock(
                                                    toolUseId: toolUseId,
                                                    content: content,
                                                    isError: isError
                                                ))
                                                break
                                            }
                                        default:
                                            break
                                        }
                                    }
                                }
                            }
                            
                            streamingBlocks = updatedBlocks
                            updateStreamingMessage(assistantMessage, blocks: streamingBlocks)
                        }
                        
                    case "system":
                        // System messages are handled separately, not as content blocks
                        break
                        
                    case "result":
                        // Result messages appear at the end
                        break
                        
                    default:
                        break
                    }
                }
            }
            
            // Final update with JSON data
            if !jsonMessages.isEmpty {
                let jsonData = jsonMessages.joined(separator: "\n").data(using: .utf8)
                updateMessageWithJSON(assistantMessage, content: fullContent, originalJSON: jsonData)
            } else if !fullContent.isEmpty {
                updateMessage(assistantMessage, with: fullContent)
            } else {
                // No content received - remove the empty assistant message
                removeMessage(assistantMessage)
            }
            
        } catch {
            updateMessage(assistantMessage, with: "Failed to get response: \(error.localizedDescription)")
        }
        
        streamingMessage = nil
        streamingBlocks = []
        isProcessing = false
    }
    
    /// Clear all messages and start fresh
    func clearChat() {
        // Delete persisted messages
        if let modelContext = modelContext {
            for message in messages {
                modelContext.delete(message)
            }
            
            do {
                try modelContext.save()
            } catch {
                print("Failed to delete messages: \(error)")
            }
        }
        
        messages.removeAll()
        claudeService.clearSessions()
    }
    
    // MARK: - Private Methods
    
    /// Load messages for the current project
    private func loadMessages() {
        guard let modelContext = modelContext,
              let projectId = projectId else { return }
        
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { message in
                message.projectId == projectId
            },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        
        do {
            messages = try modelContext.fetch(descriptor)
        } catch {
            print("Failed to load messages: \(error)")
            messages = []
        }
    }
    
    /// Create and save a new message
    private func createMessage(content: String, role: MessageRole) -> Message {
        let message = Message(content: content, role: role, projectId: projectId)
        messages.append(message)
        saveMessage(message)
        return message
    }
    
    /// Update message content
    private func updateMessage(_ message: Message, with content: String) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index].content = content
            saveChanges()
        }
    }
    
    /// Update message with content and original JSON
    private func updateMessageWithJSON(_ message: Message, content: String, originalJSON: Data?) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index].content = content
            messages[index].originalJSON = originalJSON
            saveChanges()
        }
    }
    
    /// Update streaming message with blocks
    private func updateStreamingMessage(_ message: Message, blocks: [ContentBlock]) {
        // Update the streaming blocks for real-time display
        self.streamingBlocks = blocks
        
        // Don't update the message content during streaming
        // The final update will happen when streaming is complete
        // This preserves the original JSON structure with proper tool formatting
    }
    
    /// Save a message to persistence
    private func saveMessage(_ message: Message) {
        guard let modelContext = modelContext else { return }
        
        modelContext.insert(message)
        saveChanges()
    }
    
    /// Save any pending changes
    private func saveChanges() {
        guard let modelContext = modelContext else { return }
        
        do {
            try modelContext.save()
        } catch {
            print("Failed to save: \(error)")
        }
    }
    
    /// Add an error message to the chat
    private func addErrorMessage(_ text: String) {
        _ = createMessage(content: text, role: .assistant)
    }
    
    /// Remove a message from the chat
    private func removeMessage(_ message: Message) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages.remove(at: index)
            if let modelContext = modelContext {
                modelContext.delete(message)
                saveChanges()
            }
        }
    }
    
    /// Create a ToolResultBlock without decoder
    private func createToolResultBlock(toolUseId: String, content: String, isError: Bool) -> ToolResultBlock {
        // We need to create a dummy JSON data to decode the ToolResultBlock
        let blockData: [String: Any] = [
            "type": "tool_result",
            "tool_use_id": toolUseId,
            "content": content,
            "is_error": isError
        ]
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: blockData),
           let toolBlock = try? JSONDecoder().decode(ToolResultBlock.self, from: jsonData) {
            return toolBlock
        }
        
        // This should never happen but provide a fallback
        fatalError("Failed to create ToolResultBlock")
    }
}