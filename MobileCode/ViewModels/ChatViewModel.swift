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

// MARK: - Notifications
extension Notification.Name {
    static let mcpConfigurationChanged = Notification.Name("mcpConfigurationChanged")
    static let sshConnectionsRecovered = Notification.Name("sshConnectionsRecovered")
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
    var streamingBlocks: [ContentBlock] = []
    
    /// Model context for persistence
    private var modelContext: ModelContext?
    
    /// Current project ID
    private var projectId: UUID?
    
    /// Claude Code service reference
    private let claudeService = ClaudeCodeService.shared
    
    /// MCP service reference
    private let mcpService = MCPService.shared
    
    /// Loading state for previous session
    var isLoadingPreviousSession = false
    
    /// Active session indicator - shows when resuming a previous session
    var showActiveSessionIndicator = false
    
    /// Track if we've already checked for previous session
    private var hasCheckedForPreviousSession = false
    
    /// Track the active session check task
    private var sessionCheckTask: Task<Void, Never>?
    
    /// Track recovered session content to prevent duplicates
    private var recoveredSessionContent: Set<String> = []
    
    /// Track if configuration is in progress to prevent race conditions
    private var isConfiguring = false
    
    /// Cached MCP servers for the current project
    private var cachedMCPServers: [MCPServer] = []
    
    /// Track if MCP servers are being fetched
    private var isFetchingMCPServers = false
    
    // MARK: - Lifecycle
    
    init() {
        // Listen for MCP configuration changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMCPConfigurationChanged),
            name: .mcpConfigurationChanged,
            object: nil
        )
    }
    
    deinit {
        print("📝 ChatViewModel deinit: Called")
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Configuration
    
    /// Configure the view model with model context and project
    func configure(modelContext: ModelContext, projectId: UUID) {
        print("📝 configure: Called with projectId: \(projectId)")
        
        // Prevent concurrent configuration
        guard !isConfiguring else {
            print("📝 configure: Already configuring, skipping")
            return
        }
        
        isConfiguring = true
        defer { isConfiguring = false }
        
        // Always clear loading states at start to prevent stale UI
        isLoadingPreviousSession = false
        showActiveSessionIndicator = false
        print("📝 configure: Cleared loading states")
        
        // Skip if already configured for the same project
        if self.projectId == projectId && self.modelContext === modelContext {
            print("📝 configure: Already configured for same project, returning")
            return
        }
        
        // Cancel any existing session check task before resetting
        sessionCheckTask?.cancel()
        sessionCheckTask = nil
        
        // Reset the flag when project changes
        if self.projectId != projectId {
            hasCheckedForPreviousSession = false
            // Also reset loading states when switching projects
            isLoadingPreviousSession = false
            showActiveSessionIndicator = false
            // Clear cached MCP servers when switching projects
            cachedMCPServers = []
        }
        
        self.modelContext = modelContext
        self.projectId = projectId
        loadMessages()
        
        // Check Claude installation and fetch MCP servers when configuring
        Task {
            if let server = ProjectContext.shared.activeServer {
                _ = await claudeService.checkClaudeInstallation(for: server)
            }
            
            // Fetch MCP servers only if cache is empty
            if cachedMCPServers.isEmpty {
                await fetchMCPServers()
            }
        }
        
        // Check for previous session after configuration (only if not already checked)
        if !hasCheckedForPreviousSession {
            // Cancel any existing check
            sessionCheckTask?.cancel()
            
            // Create new check task
            sessionCheckTask = Task {
                // Mark as checked inside the task to prevent race conditions
                hasCheckedForPreviousSession = true
                await checkForPreviousSession()
            }
        }
    }
    
    // MARK: - Public Methods
    
    /// Send a message to Claude
    /// - Parameter text: The message text
    func sendMessage(_ text: String) async {
        guard let project = ProjectContext.shared.activeProject else {
            addErrorMessage("No active project. Please select a project first.")
            return
        }
        
        // Check if Claude is installed
        if let server = ProjectContext.shared.activeServer,
           let isInstalled = claudeService.claudeInstallationStatus[server.id],
           !isInstalled {
            addErrorMessage("Claude CLI is not installed on this server. Please install it first.")
            return
        }
        
        // Check for existing active streaming message
        if let existingId = project.activeStreamingMessageId {
            addErrorMessage("Previous message is still processing. Please wait for it to complete or clear the chat.")
            return
        }
        
        // If there's a previous message still streaming, mark it as interrupted
        if let previousStreaming = messages.last(where: { $0.isStreaming }) {
            previousStreaming.isStreaming = false
            previousStreaming.isComplete = true
            if previousStreaming.content.isEmpty && previousStreaming.originalJSON == nil {
                updateMessage(previousStreaming, with: "[Response was interrupted by new message]")
            }
            saveChanges()
        }
        
        // Clear any existing streaming state
        streamingMessage = nil
        streamingBlocks = []
        isProcessing = false
        
        // Save changes before starting new session
        saveChanges()
        
        // Create and save user message
        _ = createMessage(content: text, role: .user)
        
        // Create placeholder for assistant response with isComplete = false and isStreaming = true
        let assistantMessage = createMessage(content: "", role: .assistant, isComplete: false, isStreaming: true)
        streamingMessage = assistantMessage
        isProcessing = true
        
        // Store the message ID in project for recovery
        project.activeStreamingMessageId = assistantMessage.id
        project.updateLastModified()
        saveChanges()
        
        // Validate that the ID was properly stored
        print("📝 Stored active streaming message ID: \(assistantMessage.id)")
        print("📝 Project active streaming ID: \(project.activeStreamingMessageId?.uuidString ?? "nil")")
        
        // Use cached MCP servers or fetch if not available
        let mcpServers = cachedMCPServers
        print("📝 Using \(mcpServers.count) cached MCP servers for message")
        
        // Stream response from Claude
        do {
            let stream = claudeService.sendMessage(text, in: project, messageId: assistantMessage.id, mcpServers: mcpServers)
            var fullContent = ""
            var jsonMessages: [String] = []
            self.streamingBlocks = [] // Clear previous streaming blocks
            
            for try await chunk in stream {
                // Periodically save project changes (for nohup tracking)
                saveChanges()
                
                if chunk.isError {
                    print("🔴 Error chunk received: \(chunk.content)")
                    
                    // Check if this is a Claude not installed error
                    if let error = chunk.metadata?["error"] as? String, error == "claude_not_installed" {
                        // Mark Claude as not installed for this server
                        if let server = ProjectContext.shared.activeServer {
                            ClaudeCodeService.shared.claudeInstallationStatus[server.id] = false
                        }
                    }
                    
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
                        // Result messages indicate session completion
                        // Immediately mark the message as complete
                        assistantMessage.isComplete = true
                        assistantMessage.isStreaming = false
                        
                        // Update in messages array too
                        if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
                            messages[index].isStreaming = false
                            messages[index].isComplete = true
                        }
                        
                        // Clear the active streaming message ID
                        project.activeStreamingMessageId = nil
                        
                        // Save immediately to ensure persistence
                        saveChanges()
                        
                        // Also clear UI streaming state since we're done
                        streamingMessage = nil
                        streamingBlocks = []
                        isProcessing = false
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
            // Mark as complete and stop streaming even on error
            assistantMessage.isComplete = true
            assistantMessage.isStreaming = false
            
            // Ensure the message is properly updated in the messages array
            if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
                messages[index].isStreaming = false
                messages[index].isComplete = true
            }
            
            saveChanges()
        }
        
        // Clear UI streaming state
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
        hasCheckedForPreviousSession = false
        sessionCheckTask?.cancel()
        isLoadingPreviousSession = false
        print("📝 clearChat: Set isLoadingPreviousSession = false")
        recoveredSessionContent.removeAll()
        
        // Clear active streaming message ID when clearing chat
        if let project = ProjectContext.shared.activeProject {
            project.activeStreamingMessageId = nil
        }
    }
    
    /// Clear all loading states - useful when view disappears
    func clearLoadingStates() {
        // Cancel any pending session check
        sessionCheckTask?.cancel()
        sessionCheckTask = nil
        
        isLoadingPreviousSession = false
        showActiveSessionIndicator = false
        print("📝 clearLoadingStates: Cleared all loading states and cancelled pending tasks")
    }
    
    /// Clean up resources before view disappears
    func cleanup() {
        // Cancel any pending tasks
        sessionCheckTask?.cancel()
        sessionCheckTask = nil
        
        // Clear references
        streamingMessage = nil
        streamingBlocks = []
        
        print("📝 cleanup: Cleaned up all resources")
    }
    
    /// Clear all streaming states safely
    private func clearAllStreamingStates() {
        updateStreamingState(
            isProcessing: false,
            streamingMessage: nil as Message?,
            streamingBlocks: [],
            showActiveSessionIndicator: false,
            isLoadingPreviousSession: false
        )
    }
    
    /// Fetch MCP servers for the current project
    @MainActor
    func fetchMCPServers() async {
        guard let project = ProjectContext.shared.activeProject else {
            print("📝 fetchMCPServers: No active project")
            return
        }
        
        guard !isFetchingMCPServers else {
            print("📝 fetchMCPServers: Already fetching")
            return
        }
        
        isFetchingMCPServers = true
        defer { isFetchingMCPServers = false }
        
        do {
            cachedMCPServers = try await mcpService.fetchServers(for: project)
            print("📝 Fetched and cached \(cachedMCPServers.count) MCP servers")
            
            // Log connected servers
            let connectedServers = cachedMCPServers.filter { $0.status == .connected }
            print("📝 Connected MCP servers: \(connectedServers.map { $0.name }.joined(separator: ", "))")
        } catch {
            print("⚠️ Failed to fetch MCP servers: \(error)")
            cachedMCPServers = []
        }
    }
    
    /// Refresh MCP servers (useful after configuration changes)
    func refreshMCPServers() async {
        cachedMCPServers = []
        await fetchMCPServers()
    }
    
    /// Invalidate MCP cache (call when configuration changes)
    func invalidateMCPCache() {
        cachedMCPServers = []
        print("📝 MCP cache invalidated")
    }
    
    /// Handle MCP configuration changed notification
    @objc private func handleMCPConfigurationChanged() {
        print("📝 MCP configuration changed notification received")
        print("📝 Current cached MCP servers before invalidation: \(cachedMCPServers.count)")
        invalidateMCPCache()
        
        // Fetch new servers in background
        Task {
            await fetchMCPServers()
            print("📝 MCP servers after refresh: \(cachedMCPServers.count)")
        }
    }
    
    /// Batch update streaming state to prevent UI flicker
    @MainActor
    func updateStreamingState(
        isProcessing: Bool? = nil,
        streamingMessage: Message? = nil,
        streamingBlocks: [ContentBlock]? = nil,
        showActiveSessionIndicator: Bool? = nil,
        isLoadingPreviousSession: Bool? = nil
    ) {
        if let isProcessing = isProcessing {
            self.isProcessing = isProcessing
        }
        if let streamingMessage = streamingMessage {
            self.streamingMessage = streamingMessage
        }
        if let streamingBlocks = streamingBlocks {
            self.streamingBlocks = streamingBlocks
        }
        if let showActiveSessionIndicator = showActiveSessionIndicator {
            self.showActiveSessionIndicator = showActiveSessionIndicator
        }
        if let isLoadingPreviousSession = isLoadingPreviousSession {
            self.isLoadingPreviousSession = isLoadingPreviousSession
        }
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
            
            // Clear any stale UI state first
            streamingMessage = nil
            streamingBlocks = []
            isProcessing = false
            isLoadingPreviousSession = false
            print("📝 loadMessages: Set isLoadingPreviousSession = false")
            
            // Check if the last assistant message was streaming when app closed
            if let lastMessage = messages.last,
               lastMessage.role == .assistant,
               lastMessage.isStreaming {
                
                // Check if the message actually completed (has a result message)
                let hasCompletedSession = lastMessage.structuredMessages?.contains { $0.type == "result" } ?? false
                
                if hasCompletedSession {
                    // Message completed successfully, just fix the streaming flag
                    lastMessage.isStreaming = false
                    lastMessage.isComplete = true
                    saveChanges()
                } else {
                    // Message was truly interrupted - show streaming state
                    streamingMessage = lastMessage
                    isProcessing = true
                    
                    // Parse existing content to restore streaming blocks
                    if let structuredMessages = lastMessage.structuredMessages {
                        var blocks: [ContentBlock] = []
                        
                        for structured in structuredMessages {
                            if structured.type == "assistant",
                               let messageContent = structured.message {
                                // Extract content blocks from the assistant message
                                switch messageContent.content {
                                case .blocks(let contentBlocks):
                                    blocks.append(contentsOf: contentBlocks)
                                case .text(let text):
                                    blocks.append(.text(TextBlock(type: "text", text: text)))
                                }
                            }
                        }
                        
                        streamingBlocks = blocks
                    }
                }
            }
        } catch {
            print("Failed to load messages: \(error)")
            messages = []
        }
    }
    
    /// Create and save a new message
    private func createMessage(content: String, role: MessageRole, isComplete: Bool = true, isStreaming: Bool = false) -> Message {
        let message = Message(content: content, role: role, projectId: projectId, originalJSON: nil, isComplete: isComplete, isStreaming: isStreaming)
        
        // For assistant messages, add a small time offset to ensure they come after user messages
        if role == .assistant {
            message.timestamp = Date().addingTimeInterval(0.001) // 1 millisecond later
        }
        
        // Save the message
        saveMessage(message)
        
        // Add to messages array in the correct position
        let insertIndex = messages.firstIndex { $0.timestamp > message.timestamp } ?? messages.count
        messages.insert(message, at: insertIndex)
        
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
        if let modelContext = modelContext {
            modelContext.delete(message)
            saveChanges()
            // Reload messages from database to ensure consistency
            loadMessages()
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
    
    /// Check for previous session and recover if needed
    func checkForPreviousSession() async {
        print("📝 checkForPreviousSession: Starting")
        
        // Prevent concurrent checks
        guard !isLoadingPreviousSession else {
            print("📝 checkForPreviousSession: Already checking, skipping")
            return
        }
        
        // Set loading state with timeout protection
        isLoadingPreviousSession = true
        
        // Ensure loading state is cleared even if errors occur
        defer {
            Task { @MainActor in
                isLoadingPreviousSession = false
            }
        }
        
        guard let project = ProjectContext.shared.activeProject,
              let server = ProjectContext.shared.activeServer else { 
            print("📝 Recovery: No active project or server")
            clearAllStreamingStates()
            return 
        }
        
        // Check if we have an active streaming message to recover
        guard let messageId = project.activeStreamingMessageId else {
            print("📝 Recovery: No active streaming message ID found")
            clearAllStreamingStates()
            return
        }
        
        print("📝 Recovery: Found active streaming message ID: \(messageId)")
        print("📝 Recovery: Current messages count: \(messages.count)")
        
        let sessionInfo = await claudeService.checkForPreviousSession(
            project: project,
            server: server
        )
        
        print("📝 Recovery: Session check result - hasActiveSession: \(sessionInfo.hasActiveSession), hasOutput: \(sessionInfo.recentOutput != nil), messageId: \(sessionInfo.messageId?.uuidString ?? "nil")")
        
        if let recentOutput = sessionInfo.recentOutput, 
           !recentOutput.isEmpty,
           let recoveryMessageId = sessionInfo.messageId {
            print("📝 Recovery: Found recent output (\(recentOutput.count) chars) for message ID: \(recoveryMessageId)")
            
            // Parse and display the recent output
            await displayRecoveredConversation(recentOutput, project: project, messageId: recoveryMessageId)
            
            // If process is still running, resume streaming
            if sessionInfo.hasActiveSession {
                print("📝 Recovery: Process is still active, resuming streaming")
                showActiveSessionIndicator = true
                await resumeActiveSession(project: project, server: server, messageId: recoveryMessageId)
                // Ensure indicator is cleared after resume completes
                showActiveSessionIndicator = false
            } else {
                print("📝 Recovery: Process completed, cleaning up states")
                // IMPORTANT: Ensure ALL streaming states are cleared for completed sessions
                updateStreamingState(
                    isProcessing: false,
                    streamingMessage: nil as Message?,
                    streamingBlocks: [],
                    showActiveSessionIndicator: false
                )
                
                // Also fix any lingering streaming messages in the messages array
                if let lastMessage = messages.last,
                   lastMessage.role == .assistant,
                   lastMessage.isStreaming {
                    print("📝 Recovery: Fixing lingering streaming state on last message")
                    lastMessage.isStreaming = false
                    lastMessage.isComplete = true
                    saveChanges()
                }
                
                // Clean up files if session is not active
                await claudeService.cleanupPreviousSessionFiles(project: project, server: server, messageId: recoveryMessageId)
            }
        } else {
            print("📝 Recovery: No previous session to recover")
            // No previous output - ensure clean state
            await MainActor.run {
                isProcessing = false
                streamingMessage = nil
                streamingBlocks = []
                showActiveSessionIndicator = false
                isLoadingPreviousSession = false
                print("📝 checkForPreviousSession: Set isLoadingPreviousSession = false (no session to recover)")
            }
            
            // Also fix any lingering streaming messages that may have been loaded
            if let lastMessage = messages.last,
               lastMessage.role == .assistant,
               lastMessage.isStreaming {
                print("📝 Recovery: Fixing lingering streaming state on last message (no session)")
                lastMessage.isStreaming = false
                lastMessage.isComplete = true
                saveChanges()
            }
        }
        
        // Final ensure loading state is cleared
        await MainActor.run {
            isLoadingPreviousSession = false
            print("📝 checkForPreviousSession: Set isLoadingPreviousSession = false (final)")
        }
        print("📝 checkForPreviousSession: Completed")
    }
    
    /// Display recovered conversation from output file
    private func displayRecoveredConversation(_ output: String, project: RemoteProject, messageId: UUID) async {
        // Parse the output lines and reconstruct messages
        let lines = output.components(separatedBy: .newlines)
        var jsonMessages: [String] = []
        var assistantContent = ""
        var hasContent = false
        var hasResultMessage = false
        var userCommands: [(command: String, timestamp: Date)] = []
        
        for line in lines where !line.isEmpty {
            // Skip the nohup: ignoring input line
            if line.contains("nohup: ignoring input") {
                continue
            }
            
            if let chunk = StreamingJSONParser.parseStreamingLine(line) {
                if let metadata = chunk.metadata,
                   let originalJSON = metadata["originalJSON"] as? String {
                    jsonMessages.append(originalJSON)
                    hasContent = true
                    
                    // Check for different message types
                    if let type = metadata["type"] as? String {
                        switch type {
                        case "result":
                            hasResultMessage = true
                        case "assistant":
                            if let content = metadata["content"] as? [[String: Any]] {
                                // Extract text content from assistant messages
                                for block in content {
                                    if let blockType = block["type"] as? String,
                                       blockType == "text",
                                       let text = block["text"] as? String {
                                        assistantContent = text
                                    }
                                }
                            }
                        case "system":
                            // Extract user commands from system messages
                            if let command = metadata["command"] as? String {
                                userCommands.append((command: command, timestamp: Date()))
                                print("📝 Recovery: Found user command: \(command)")
                            }
                        default:
                            break
                        }
                    }
                }
            }
        }
        
        if hasContent && !jsonMessages.isEmpty {
            print("📝 Recovery: Found \(jsonMessages.count) JSON messages to recover")
            print("📝 Recovery: Found \(userCommands.count) user commands")
            
            // Reload messages to ensure we have the latest state
            loadMessages()
            
            print("📝 Recovery: Total messages in conversation: \(messages.count)")
            for (index, msg) in messages.enumerated() {
                print("📝 Message \(index): \(msg.role) - \(msg.content.prefix(50))...")
            }
            
            // Find the existing message by ID
            var targetMessage: Message? = messages.first(where: { $0.id == messageId })
            
            if targetMessage == nil {
                print("📝 Warning: Could not find message with ID \(messageId), creating recovery message")
                
                // Create a new message for the recovered content
                let recoveryMessage = Message(
                    content: assistantContent,
                    role: .assistant,
                    projectId: projectId,
                    originalJSON: nil,
                    isComplete: hasResultMessage,
                    isStreaming: !hasResultMessage
                )
                
                // Use the original message ID to maintain consistency
                recoveryMessage.id = messageId
                
                // Save the recovery message
                if let modelContext = modelContext {
                    modelContext.insert(recoveryMessage)
                    saveChanges()
                    
                    // Reload messages to include the new recovery message
                    loadMessages()
                    
                    // Find the message again
                    targetMessage = messages.first(where: { $0.id == messageId })
                }
            }
            
            // Update the message with recovered content
            if let existingMessage = targetMessage {
                // Preserve existing content and JSON
                var existingJSONMessages: [String] = []
                if let existingJSON = existingMessage.originalJSON,
                   let jsonString = String(data: existingJSON, encoding: .utf8) {
                    existingJSONMessages = jsonString.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    print("📝 Recovery: Found \(existingJSONMessages.count) existing JSON messages")
                }
                
                // Merge existing and new JSON messages
                let allJSONMessages = existingJSONMessages + jsonMessages
                let mergedJSONData = allJSONMessages.joined(separator: "\n").data(using: .utf8)
                
                // Update content - append if we have new assistant text
                if !assistantContent.isEmpty {
                    if existingMessage.content.isEmpty {
                        existingMessage.content = assistantContent
                    } else if !existingMessage.content.contains(assistantContent) {
                        // Only append if the new content isn't already in the message
                        existingMessage.content = assistantContent
                    }
                }
                
                existingMessage.originalJSON = mergedJSONData
                existingMessage.isComplete = hasResultMessage
                existingMessage.isStreaming = !hasResultMessage
                
                print("📝 Recovery: Updated message with \(allJSONMessages.count) total JSON messages")
                
                // Save changes
                saveChanges()
                
                print("📝 Successfully recovered message content for ID: \(messageId)")
                print("📝 Recovery: Assistant content: '\(assistantContent.prefix(50))...'")
                print("📝 Recovery: Has system messages: \(jsonMessages.contains { $0.contains("\"type\":\"system\"") })")
            } else {
                print("❌ Failed to create or find message for recovery")
            }
            
            // Clear any UI streaming state since we've recovered the content
            isProcessing = !hasResultMessage
            streamingMessage = hasResultMessage ? nil : targetMessage
            streamingBlocks = []
            
            // Clear the active streaming message ID if session is complete
            if hasResultMessage {
                project.activeStreamingMessageId = nil
                saveChanges()
            }
        }
    }
    
    /// Resume an active session
    private func resumeActiveSession(project: RemoteProject, server: Server, messageId: UUID) async {
        // Find the existing message to resume
        var existingMessage = messages.first(where: { $0.id == messageId })
        
        if existingMessage == nil {
            print("📝 Warning: Could not find message with ID \(messageId), creating message for active session")
            
            // Create a new message for the active session
            let activeMessage = Message(
                content: "",
                role: .assistant,
                projectId: projectId,
                originalJSON: nil,
                isComplete: false,
                isStreaming: true
            )
            
            // Use the original message ID to maintain consistency
            activeMessage.id = messageId
            
            // Save the active message
            if let modelContext = modelContext {
                modelContext.insert(activeMessage)
                saveChanges()
                
                // Reload messages to include the new message
                loadMessages()
                
                // Find the message again
                existingMessage = messages.first(where: { $0.id == messageId })
            }
            
            if existingMessage == nil {
                print("❌ Failed to create message for active session recovery")
                showActiveSessionIndicator = false
                return
            }
        }
        
        // Set it as the streaming message
        streamingMessage = existingMessage
        existingMessage!.isStreaming = true
        isProcessing = true
        saveChanges()
        
        // Resume streaming from the session
        let stream = claudeService.resumeStreamingFromPreviousSession(
            project: project,
            server: server,
            messageId: messageId
        )
        
        // Process the streaming response
        do {
            var jsonMessages: [String] = []
            var fullContent = ""
            
            for try await chunk in stream {
                // Periodically save project changes (for nohup tracking)
                saveChanges()
                
                // Collect JSON for structured message updates
                if let originalJSON = chunk.metadata?["originalJSON"] as? String {
                    jsonMessages.append(originalJSON)
                }
                
                // Update the existing message with accumulated JSON data
                if !jsonMessages.isEmpty, let existingMsg = existingMessage {
                    let currentJsonData = jsonMessages.joined(separator: "\n").data(using: .utf8)
                    updateMessageWithJSON(existingMsg, content: fullContent, originalJSON: currentJsonData)
                }
                
                // Process content based on message type
                if let type = chunk.metadata?["type"] as? String {
                    switch type {
                    case "assistant":
                        // Parse blocks and update streaming views
                        if let blocks = chunk.metadata?["content"] as? [[String: Any]] {
                            for block in blocks {
                                if let blockType = block["type"] as? String,
                                   blockType == "text",
                                   let text = block["text"] as? String {
                                    fullContent = text
                                }
                            }
                        }
                        
                    case "result":
                        // Mark as complete when result received
                        existingMessage?.isComplete = true
                        existingMessage?.isStreaming = false
                        showActiveSessionIndicator = false
                        saveChanges()
                        break
                        
                    default:
                        break
                    }
                }
            }
            
            // Final update with JSON data
            if !jsonMessages.isEmpty, let existingMsg = existingMessage {
                let jsonData = jsonMessages.joined(separator: "\n").data(using: .utf8)
                updateMessageWithJSON(existingMsg, content: fullContent, originalJSON: jsonData)
            }
            
        } catch {
            print("Error resuming stream: \(error)")
            existingMessage?.content = "Error resuming session: \(error.localizedDescription)"
            existingMessage?.isStreaming = false
            existingMessage?.isComplete = true
            showActiveSessionIndicator = false
        }
        
        // Mark as complete when done
        existingMessage?.isStreaming = false
        existingMessage?.isComplete = true
        streamingMessage = nil
        isProcessing = false
        showActiveSessionIndicator = false
        
        // Clear the active streaming message ID
        project.activeStreamingMessageId = nil
        saveChanges()
        
        // Clean up files after completion
        await claudeService.cleanupPreviousSessionFiles(project: project, server: server, messageId: messageId)
    }
}