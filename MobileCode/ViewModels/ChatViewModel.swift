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

/// Enum representing different types of streaming blocks
enum StreamingBlock {
    case text(String)
    case toolUse(id: String, name: String, input: [String: Any])
    case toolResult(toolUseId: String, isError: Bool, content: String)
    case system(sessionId: String?, cwd: String?, model: String?)
}

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
    var streamingBlocks: [StreamingBlock] = []
    
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
    }
    
    // MARK: - Public Methods
    
    /// Send a message to Claude
    /// - Parameter text: The message text
    func sendMessage(_ text: String) async {
        guard let project = ProjectContext.shared.activeProject else {
            await addErrorMessage("No active project. Please select a project first.")
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
                    fullContent = chunk.content.isEmpty ? "Authentication error occurred" : chunk.content
                    
                    // For error chunks, we need to ensure they're displayed
                    // Create a simple text block for the error message
                    streamingBlocks = [.text(fullContent)]
                    updateStreamingMessage(assistantMessage, blocks: streamingBlocks)
                    hasReceivedContent = true
                    break
                }
                
                // Extract original JSON from metadata
                if let originalJSON = chunk.metadata?["originalJSON"] as? String {
                    jsonMessages.append(originalJSON)
                }
                
                // Process content based on message type
                if let type = chunk.metadata?["type"] as? String {
                    switch type {
                    case "assistant":
                        hasReceivedContent = true
                        
                        // Parse blocks and create streaming views
                        if let blocks = chunk.metadata?["content"] as? [[String: Any]] {
                            // Keep track of completed blocks (text that's done, tool results)
                            var completedBlocks: [StreamingBlock] = []
                            var activeBlocks: [StreamingBlock] = []
                            var currentTextBlock: StreamingBlock? = nil
                            
                            // First, preserve any existing completed blocks
                            for existingBlock in streamingBlocks {
                                switch existingBlock {
                                case .toolResult(_, _, _):
                                    // Always keep tool results
                                    completedBlocks.append(existingBlock)
                                case .text(let existingText):
                                    // Check if this text block appears in the new blocks
                                    var foundInNew = false
                                    for newBlock in blocks {
                                        if let blockType = newBlock["type"] as? String,
                                           blockType == "text",
                                           let newText = newBlock["text"] as? String {
                                            // If the new text starts with the existing text, it's still being built
                                            if newText.hasPrefix(existingText) {
                                                foundInNew = true
                                                currentTextBlock = .text(newText)
                                                break
                                            } else if existingText == newText {
                                                // Exact match - text is complete
                                                foundInNew = true
                                                completedBlocks.append(existingBlock)
                                                break
                                            }
                                        }
                                    }
                                    // If not found in new blocks, it's completed
                                    if !foundInNew {
                                        completedBlocks.append(existingBlock)
                                    }
                                case .toolUse(let id, _, _):
                                    // Check if this tool has a result
                                    let hasResult = streamingBlocks.contains { block in
                                        if case .toolResult(let resultId, _, _) = block {
                                            return resultId == id
                                        }
                                        return false
                                    }
                                    if !hasResult {
                                        // Tool still active, will be handled below
                                        break
                                    }
                                case .system(_, _, _):
                                    // Keep system blocks
                                    completedBlocks.append(existingBlock)
                                }
                            }
                            
                            // Process new blocks
                            for block in blocks {
                                if let blockType = block["type"] as? String {
                                    switch blockType {
                                    case "text":
                                        if let text = block["text"] as? String {
                                            // Skip if we already handled this text block above
                                            if currentTextBlock != nil {
                                                if case .text(let currentText) = currentTextBlock!, currentText == text {
                                                    continue
                                                }
                                            }
                                            // Skip if this text is already in completed blocks
                                            let alreadyCompleted = completedBlocks.contains { block in
                                                if case .text(let completedText) = block {
                                                    return completedText == text
                                                }
                                                return false
                                            }
                                            if !alreadyCompleted {
                                                activeBlocks.append(.text(text))
                                            }
                                        }
                                    case "tool_use":
                                        if let name = block["name"] as? String,
                                           let id = block["id"] as? String {
                                            let input = block["input"] as? [String: Any] ?? [:]
                                            // Check if this tool is already completed
                                            let isCompleted = completedBlocks.contains { block in
                                                if case .toolResult(let completedId, _, _) = block {
                                                    return completedId == id
                                                }
                                                return false
                                            }
                                            if !isCompleted {
                                                activeBlocks.append(.toolUse(id: id, name: name, input: input))
                                            }
                                        }
                                    case "tool_result":
                                        // Tool results are handled in the "user" type messages
                                        break
                                    default:
                                        break
                                    }
                                }
                            }
                            
                            // Add current text block if it exists
                            if let currentText = currentTextBlock {
                                activeBlocks.insert(currentText, at: 0)
                            }
                            
                            // Combine completed blocks with active blocks
                            streamingBlocks = completedBlocks + activeBlocks
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
                                        if case .toolUse(let id, _, _) = existingBlock,
                                           id == toolUseId {
                                            // Replace tool use with tool result
                                            updatedBlocks[index] = .toolResult(toolUseId: toolUseId, isError: isError, content: content)
                                            break
                                        }
                                    }
                                }
                            }
                            
                            streamingBlocks = updatedBlocks
                            updateStreamingMessage(assistantMessage, blocks: streamingBlocks)
                        }
                        
                    case "system":
                        // Show system info during streaming
                        if let subtype = chunk.metadata?["subtype"] as? String,
                           subtype == "init" {
                            let sessionId = chunk.metadata?["sessionId"] as? String
                            let cwd = chunk.metadata?["cwd"] as? String
                            let model = chunk.metadata?["model"] as? String
                            streamingBlocks.append(.system(sessionId: sessionId, cwd: cwd, model: model))
                            updateStreamingMessage(assistantMessage, blocks: streamingBlocks)
                        }
                        
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
                
                // Also update structured content if we have streaming blocks
                if !streamingBlocks.isEmpty && hasReceivedContent {
                    updateStreamingMessage(assistantMessage, blocks: streamingBlocks)
                }
            } else if !fullContent.isEmpty {
                updateMessage(assistantMessage, with: fullContent)
                
                // Also update structured content if we have streaming blocks
                if !streamingBlocks.isEmpty && hasReceivedContent {
                    updateStreamingMessage(assistantMessage, blocks: streamingBlocks)
                }
            } else if hasReceivedContent && !streamingBlocks.isEmpty {
                // Even if fullContent is empty, update with streaming blocks
                updateStreamingMessage(assistantMessage, blocks: streamingBlocks)
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
    private func updateStreamingMessage(_ message: Message, blocks: [StreamingBlock]) {
        // Update the streaming blocks for real-time display
        self.streamingBlocks = blocks
        
        // Create structured content for proper rendering
        var contentBlocks: [[String: Any]] = []
        var textContent = ""
        
        for block in blocks {
            switch block {
            case .text(let text):
                contentBlocks.append([
                    "type": "text",
                    "text": text
                ])
                textContent += text
            case .toolUse(let id, let name, let input):
                contentBlocks.append([
                    "type": "tool_use",
                    "id": id,
                    "name": name,
                    "input": input
                ])
                textContent += "\n🔧 \(name)"
            case .toolResult(let toolUseId, let isError, let content):
                contentBlocks.append([
                    "type": "tool_result",
                    "tool_use_id": toolUseId,
                    "is_error": isError,
                    "content": content
                ])
                let prefix = isError ? "❌" : "✓"
                textContent += "\n\(prefix) Tool Result\n\(content)"
            case .system(let sessionId, let cwd, let model):
                textContent += "\n📋 Session Info"
            }
        }
        
        // Create a structured message JSON
        let structuredMessage: [String: Any] = [
            "type": "assistant",
            "message": [
                "id": UUID().uuidString,
                "role": "assistant",
                "content": contentBlocks
            ]
        ]
        
        // Convert to JSON data
        if let jsonData = try? JSONSerialization.data(withJSONObject: structuredMessage, options: []) {
            updateMessageWithJSON(message, content: textContent, originalJSON: jsonData)
        } else if !textContent.isEmpty {
            updateMessage(message, with: textContent)
        }
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
}