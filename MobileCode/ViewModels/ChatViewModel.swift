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
            
            for try await chunk in stream {
                if chunk.isError {
                    fullContent = chunk.content
                    break
                } else if !chunk.isComplete {
                    fullContent += chunk.content
                    updateMessage(assistantMessage, with: fullContent)
                }
            }
            
            // Final update
            if !fullContent.isEmpty {
                updateMessage(assistantMessage, with: fullContent)
            }
            
        } catch {
            updateMessage(assistantMessage, with: "Failed to get response: \(error.localizedDescription)")
        }
        
        streamingMessage = nil
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