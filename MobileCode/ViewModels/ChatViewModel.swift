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
    var streamingBlocks: [ContentBlock] = [] {
        didSet {
            streamingRedrawToken = UUID()
        }
    }

    /// Token used to force ExyteChat row relayout for the streaming message.
    /// This should be updated only when streaming content changes to avoid excessive redraws.
    var streamingRedrawToken = UUID()

    /// Monotonic revision for message updates that don't change `messages.count`.
    /// Used to drive auto-scroll while streaming.
    var messagesRevision = 0
    
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

    /// Show when proxy sync retries have failed repeatedly
    var showSyncRetryIndicator = false
    
    /// Track if we've already checked for previous session
    private var hasCheckedForPreviousSession = false
    
    /// Track the active session check task
    private var sessionCheckTask: Task<Void, Never>?

    private var sessionCheckRetryCount = 0
    private let maxSessionCheckRetries = 5
    private let sessionCheckRetryDelay: TimeInterval = 0.5

    private var proxyPollingTask: Task<Void, Never>?
    private let proxyPollingInterval: TimeInterval = 5

    private var proxySyncGeneration = 0
    private var proxySyncRetryCount = 0
    private var proxySyncNextAttemptAt: Date = .distantPast
    private let maxProxySyncRetries = 3
    private let proxySyncBackoffBase: TimeInterval = 0.5
    
    /// Track recovered session content to prevent duplicates
    private var recoveredSessionContent: Set<String> = []
    
    /// Track if configuration is in progress to prevent race conditions
    private var isConfiguring = false
    
    /// Cached MCP servers for the current project
    private var cachedMCPServers: [MCPServer] = []
    
    /// Track if MCP servers are being fetched
    private var isFetchingMCPServers = false

    /// Stale streaming timeout used when recovery finds no active session
    private let staleStreamingTimeout: TimeInterval = 300

    /// Active tool permission request awaiting user input
    var activeToolApproval: ToolApprovalRequest?

    /// Queue for additional tool permission requests
    private var pendingToolApprovals: [ToolApprovalRequest] = []

    /// Track handled tool permission IDs to avoid duplicate prompts
    private var handledToolPermissionIds: Set<String> = []

    private let toolApprovalStore = ToolApprovalStore.shared

    private var pendingSaveTask: Task<Void, Never>?
    private var lastSaveTime: Date = .distantPast
    private let saveThrottleInterval: TimeInterval = 0.5

    var isAwaitingToolApproval: Bool {
        activeToolApproval != nil
    }
    
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
        print("📝 configure: Called with agentId: \(projectId)")
        
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
            print("📝 configure: Already configured for same agent, returning")
            return
        }
        
        // Cancel any existing session check task before resetting
        sessionCheckTask?.cancel()
        sessionCheckTask = nil
        
        // Reset the flag when project changes
        if self.projectId != projectId {
            hasCheckedForPreviousSession = false
            sessionCheckRetryCount = 0
            // Also reset loading states when switching projects
            isLoadingPreviousSession = false
            showActiveSessionIndicator = false
            // Clear cached MCP servers when switching projects
            cachedMCPServers = []
            // Clear tool approval state when switching projects
            activeToolApproval = nil
            pendingToolApprovals = []
            handledToolPermissionIds = []
            toolApprovalStore.ensureDefaults(for: projectId)
        }
        
        self.modelContext = modelContext
        self.projectId = projectId
        loadMessages()

        toolApprovalStore.ensureDefaults(for: projectId)
        
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
                await checkForPreviousSession()
            }
        }
    }
    
    // MARK: - Public Methods

    func startProxyPolling() {
        guard claudeService.isProxyChatEnabled else { return }
        proxyPollingTask?.cancel()
        proxyPollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let project = ProjectContext.shared.activeProject else {
                    try? await Task.sleep(nanoseconds: UInt64(self.proxyPollingInterval * 1_000_000_000))
                    continue
                }
                // Avoid triggering a full resync before the view model is configured and messages are loaded.
                guard self.projectId == project.id, self.modelContext != nil else {
                    try? await Task.sleep(nanoseconds: UInt64(self.proxyPollingInterval * 1_000_000_000))
                    continue
                }
                if !self.isProcessing && !self.isLoadingPreviousSession {
                    await self.syncProxyHistoryIfNeeded(project: project)
                }
                try? await Task.sleep(nanoseconds: UInt64(self.proxyPollingInterval * 1_000_000_000))
            }
        }
    }

    func stopProxyPolling() {
        proxyPollingTask?.cancel()
        proxyPollingTask = nil
    }

    func refreshProxyEvents() async {
        guard claudeService.isProxyChatEnabled else { return }
        guard let project = ProjectContext.shared.activeProject else { return }
        await syncProxyHistoryIfNeeded(project: project)
    }
    
    /// Send a message to Claude
    /// - Parameter text: The message text
    func sendMessage(_ text: String) async {
        guard let project = ProjectContext.shared.activeProject else {
            addErrorMessage("No active agent. Please select an agent first.")
            return
        }
        
        // Check if Claude is installed
        if let server = ProjectContext.shared.activeServer,
           let isInstalled = claudeService.claudeInstallationStatus[server.id],
           !isInstalled {
            addErrorMessage("Claude CLI is not installed on this server. Please install it first.")
            return
        }

        if claudeService.isProxyChatEnabled, let context = modelContext {
            try? await ProxyAgentIdentityService.shared.ensureProxyAgentId(for: project, modelContext: context)
        }
        
        // Check for existing active streaming message
        if let existingId = project.activeStreamingMessageId {
            let staleCutoff = Date().addingTimeInterval(-staleStreamingTimeout)
            let existingMessage = messages.first(where: { $0.id == existingId })
            let isStale = (existingMessage?.timestamp ?? project.lastModified) < staleCutoff
            
            if let existingMessage = existingMessage {
                if existingMessage.isComplete || !existingMessage.isStreaming || isStale {
                    existingMessage.isStreaming = false
                    existingMessage.isComplete = true
                    project.activeStreamingMessageId = nil
                    project.updateLastModified()
                    saveChanges()
                } else {
                    addErrorMessage("Previous message is still processing. Please wait for it to complete or clear the chat.")
                    return
                }
            } else if project.lastModified < staleCutoff {
                project.activeStreamingMessageId = nil
                project.updateLastModified()
                saveChanges()
            } else {
                addErrorMessage("Previous message is still processing. Please wait for it to complete or clear the chat.")
                return
            }
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
        let userMessage = createMessage(content: text, role: .user)
        if claudeService.isProxyChatEnabled,
           let jsonLine = proxyUserJSONLine(for: text),
           let jsonData = jsonLine.data(using: .utf8) {
            updateMessageWithJSON(userMessage, content: text, originalJSON: jsonData)
        }
        
        // Create placeholder for assistant response with isComplete = false and isStreaming = true
        let assistantMessage = createMessage(content: "", role: .assistant, isComplete: false, isStreaming: true)
        streamingMessage = assistantMessage
        streamingRedrawToken = UUID()
        isProcessing = true
        
        // Store the message ID in project for recovery
        project.activeStreamingMessageId = assistantMessage.id
        project.updateLastModified()
        saveChanges()
        
        // Validate that the ID was properly stored
        print("📝 Stored active streaming message ID: \(assistantMessage.id)")
        print("📝 Agent active streaming ID: \(project.activeStreamingMessageId?.uuidString ?? "nil")")
        
        // Use cached MCP servers or fetch if not available
        let mcpServers = cachedMCPServers
        print("📝 Using \(mcpServers.count) cached MCP servers for message")
        
        // Stream response from Claude
        do {
            let stream = claudeService.sendMessage(text, in: project, messageId: assistantMessage.id, mcpServers: mcpServers)
            var placeholderMessage: Message? = assistantMessage
            var didRenderMessage = false
            var lastAssistantTextMessage: Message?
            var seenLines = existingStreamJSONLines()
            self.streamingBlocks = [] // Clear previous streaming blocks

            for try await chunk in stream {
                // Periodically save project changes (for nohup tracking)
                saveChangesThrottled()

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

                    if let placeholder = placeholderMessage {
                        updateMessage(placeholder, with: errorText)
                        placeholder.isStreaming = false
                        placeholder.isComplete = true
                    } else {
                        _ = createMessage(content: errorText, role: .assistant)
                    }

                    placeholderMessage = nil
                    didRenderMessage = true
                    streamingMessage = nil
                    streamingBlocks = []
                    isProcessing = false
                    project.activeStreamingMessageId = nil
                    project.updateLastModified()
                    saveChanges()
                    break
                }

                guard let type = chunk.metadata?["type"] as? String else { continue }

                if type == "tool_permission" {
                    handleToolPermissionChunk(chunk, project: project)
                    continue
                }

                if type == "proxy_session" {
                    await handleProxySessionSwitch(project: project)
                    didRenderMessage = true
                    placeholderMessage = nil
                    streamingMessage = nil
                    streamingBlocks = []
                    isProcessing = false
                    break
                }

                if let jsonLine = persistedJSONLine(from: chunk) {
                    if seenLines.contains(jsonLine) {
                        if let metadata = chunk.metadata {
                            _ = applyProxyEventIdToExistingMessageIfPossible(
                                jsonLine: jsonLine,
                                metadata: metadata,
                                proxyEventId: proxyEventId(from: metadata)
                            )
                        }
                        continue
                    }
                    seenLines.insert(jsonLine)
                }

                if let message = upsertStreamMessage(from: chunk, reuseMessage: placeholderMessage, userMessage: userMessage) {
                    didRenderMessage = true
                    placeholderMessage = nil
                    streamingMessage = nil
                    streamingBlocks = []
                    if message.role == .assistant, !message.content.isEmpty {
                        lastAssistantTextMessage = message
                    }
                    project.activeStreamingMessageId = message.id
                    project.updateLastModified()
                }

                if type == "result" {
                    if let finalMessage = lastAssistantTextMessage {
                        finalMessage.timestamp = Date()
                    }
                    project.activeStreamingMessageId = nil
                    project.updateLastModified()
                    isProcessing = false
                    streamingMessage = nil
                    streamingBlocks = []
                    saveChanges()
                    break
                }
            }

            if !didRenderMessage {
                removeMessage(assistantMessage)
            }
            
        } catch {
            let errorText = "Failed to get response: \(error.localizedDescription)"
            if assistantMessage.originalJSON == nil && assistantMessage.content.isEmpty {
                updateMessage(assistantMessage, with: errorText)
                assistantMessage.isComplete = true
                assistantMessage.isStreaming = false
                
                if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
                    messages[index].isStreaming = false
                    messages[index].isComplete = true
                }
            } else {
                _ = createMessage(content: errorText, role: .assistant)
            }
            
            project.activeStreamingMessageId = nil
            project.updateLastModified()
            saveChanges()
        }
        
        // Clear UI streaming state
        streamingMessage = nil
        streamingBlocks = []
        isProcessing = false
    }
    
    /// Clear all messages and start fresh
    func clearChat() {
        proxySyncGeneration += 1

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
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        lastSaveTime = .distantPast
        messagesRevision += 1
        streamingRedrawToken = UUID()
        stopProxyPolling()
        proxySyncRetryCount = 0
        proxySyncNextAttemptAt = .distantPast
        showSyncRetryIndicator = false
        activeToolApproval = nil
        pendingToolApprovals = []
        handledToolPermissionIds = []
        proxySyncRetryCount = 0
        proxySyncNextAttemptAt = .distantPast
        showSyncRetryIndicator = false
        
        // Clear active streaming message ID when clearing chat
        if let project = ProjectContext.shared.activeProject {
            let previousProxyConversationId = project.proxyConversationId
            let previousProxyConversationGroupId = project.proxyConversationGroupId
            let previousProxyLastEventId = project.proxyLastEventId

            project.activeStreamingMessageId = nil
            if claudeService.isProxyChatEnabled {
                Task { @MainActor in
                    let previousSuffix = previousProxyConversationId.map { String($0.suffix(6)) } ?? "nil"
                    ProxyStreamDiagnostics.log("clearChat: proxy reset start prev=...\(previousSuffix) lastEvent=\(String(describing: previousProxyLastEventId))")
                    do {
                        try await claudeService.resetProxyConversation(project: project)
                        let canonicalSuffix = project.proxyConversationId.map { String($0.suffix(6)) } ?? "nil"
                        ProxyStreamDiagnostics.log("clearChat: proxy reset complete canonical=...\(canonicalSuffix)")
                    } catch {
                        ProxyStreamDiagnostics.log("clearChat: proxy reset failed error=\(error)")
                        project.proxyConversationId = previousProxyConversationId
                        project.proxyConversationGroupId = previousProxyConversationGroupId
                        project.proxyLastEventId = previousProxyLastEventId
                    }
                    saveChanges()
                    startProxyPolling()
                }
            }
        }

        saveChanges()
    }

    func markUnreadAsRead(for project: RemoteProject) {
        if project.unreadConversationId == nil,
           let conversationId = project.proxyConversationId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !conversationId.isEmpty {
            project.unreadConversationId = conversationId
        }

        let target = project.lastKnownUnreadCursor
        guard target > project.lastReadUnreadCursor else { return }
        project.lastReadUnreadCursor = target
        saveChanges()
    }
    
    /// Clear all loading states - useful when view disappears
    func clearLoadingStates() {
        // Cancel any pending session check
        sessionCheckTask?.cancel()
        sessionCheckTask = nil
        // Flush any pending throttled saves so proxy anchors/timestamps persist across view re-entries.
        saveChanges()
        stopProxyPolling()
        
        isLoadingPreviousSession = false
        showActiveSessionIndicator = false
        showSyncRetryIndicator = false
        proxySyncRetryCount = 0
        proxySyncNextAttemptAt = .distantPast
        activeToolApproval = nil
        pendingToolApprovals = []
        handledToolPermissionIds = []
        print("📝 clearLoadingStates: Cleared all loading states and cancelled pending tasks")
    }
    
    /// Clean up resources before view disappears
    func cleanup() {
        // Cancel any pending tasks
        sessionCheckTask?.cancel()
        sessionCheckTask = nil
        // Flush any pending throttled saves before tearing down the view model.
        saveChanges()
        stopProxyPolling()
        
        // Clear references
        streamingMessage = nil
        streamingBlocks = []
        showSyncRetryIndicator = false
        proxySyncRetryCount = 0
        proxySyncNextAttemptAt = .distantPast
        activeToolApproval = nil
        pendingToolApprovals = []
        handledToolPermissionIds = []
        
        print("📝 cleanup: Cleaned up all resources")
    }
    
    /// Fetch MCP servers for the current project
    @MainActor
    func fetchMCPServers() async {
        guard let project = ProjectContext.shared.activeProject else {
            print("📝 fetchMCPServers: No active agent")
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
        clearStreamingMessage: Bool = false,
        streamingBlocks: [ContentBlock]? = nil,
        showActiveSessionIndicator: Bool? = nil,
        isLoadingPreviousSession: Bool? = nil
    ) {
        if let isProcessing = isProcessing {
            self.isProcessing = isProcessing
        }
        if clearStreamingMessage {
            self.streamingMessage = nil
            streamingRedrawToken = UUID()
        } else if let streamingMessage = streamingMessage {
            self.streamingMessage = streamingMessage
            streamingRedrawToken = UUID()
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

    private func isMessageBefore(_ lhs: Message, _ rhs: Message) -> Bool {
        switch (lhs.proxyEventId, rhs.proxyEventId) {
        case let (leftId?, rightId?):
            if leftId != rightId {
                return leftId < rightId
            }
            return lhs.timestamp < rhs.timestamp
        case (_?, nil), (nil, _?), (nil, nil):
            return lhs.timestamp < rhs.timestamp
        }
    }

    private func insertionIndex(for message: Message) -> Int {
        for (index, existing) in messages.enumerated() {
            if isMessageBefore(message, existing) {
                return index
            }
        }
        return messages.count
    }

    private func proxyEventId(from metadata: [String: Any]?) -> Int? {
        if let value = metadata?["proxyEventId"] as? Int {
            return value
        }
        if let stringValue = metadata?["proxyEventId"] as? String, let value = Int(stringValue) {
            return value
        }
        return nil
    }

    private func metadataContainsToolBlocks(_ metadata: [String: Any]?) -> Bool {
        guard let blocks = metadata?["content"] as? [[String: Any]] else { return false }
        return blocks.contains { block in
            guard let type = block["type"] as? String else { return false }
            return type == "tool_use" || type == "tool_result"
        }
    }

    private func withProxyEventId(_ chunk: MessageChunk, eventId: Int?) -> MessageChunk {
        guard let eventId = eventId else { return chunk }
        var metadata = chunk.metadata ?? [:]
        metadata["proxyEventId"] = eventId
        return MessageChunk(
            content: chunk.content,
            isComplete: chunk.isComplete,
            isError: chunk.isError,
            metadata: metadata
        )
    }
    
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
            let fetched = try modelContext.fetch(descriptor)
            messages = fetched.sorted { isMessageBefore($0, $1) }

            // Keep the per-project proxy event anchor in sync with persisted messages so re-opening the chat
            // continues from deltas instead of replaying the full history.
            if claudeService.isProxyChatEnabled,
               let project = ProjectContext.shared.activeProject,
               project.id == projectId {
                if let maxEventId = messages.compactMap({ $0.proxyEventId }).max() {
                    if project.proxyLastEventId == nil || maxEventId > (project.proxyLastEventId ?? 0) {
                        project.proxyLastEventId = maxEventId
                        project.updateLastModified()
                        saveChanges()
                    }
                }
            }
            
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
                let hasCompletedSession = lastMessage.isComplete
                
                if hasCompletedSession {
                    // Message completed successfully, just fix the streaming flag
                    lastMessage.isStreaming = false
                    lastMessage.isComplete = true
                    if let project = ProjectContext.shared.activeProject,
                       project.activeStreamingMessageId == lastMessage.id {
                        project.activeStreamingMessageId = nil
                        project.updateLastModified()
                    }
                    saveChanges()
                } else {
                    // Message was truly interrupted - show streaming state
                    streamingMessage = lastMessage
                    isProcessing = true
                    streamingRedrawToken = UUID()
                    
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
    private func createMessage(
        content: String,
        role: MessageRole,
        isComplete: Bool = true,
        isStreaming: Bool = false,
        proxyEventId: Int? = nil
    ) -> Message {
        let message = Message(content: content, role: role, projectId: projectId, originalJSON: nil, isComplete: isComplete, isStreaming: isStreaming)
        message.proxyEventId = proxyEventId

        if role == .assistant {
            // For assistant messages, add a small time offset to ensure they come after user messages
            message.timestamp = Date().addingTimeInterval(0.001) // 1 millisecond later
        }
        
        // Save the message
        saveMessage(message)
        
        // Add to messages array in the correct position
        let insertIndex = insertionIndex(for: message)
        messages.insert(message, at: insertIndex)
        messagesRevision += 1
        
        return message
    }
    
    /// Update message content
    private func updateMessage(_ message: Message, with content: String) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index].content = content
            saveChanges()
            messagesRevision += 1
        }
    }
    
    /// Update message with content and original JSON
    private func updateMessageWithJSON(_ message: Message, content: String, originalJSON: Data?, proxyEventId: Int? = nil) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            let existing = messages[index]
            let hadOriginalJSON = existing.originalJSON != nil
            existing.content = content
            if let originalJSON = originalJSON {
                let mergedJSON = appendOriginalJSON(existing: existing.originalJSON, new: originalJSON)
                existing.originalJSON = mergedJSON
                ProxyStreamDiagnostics.log(
                    "message update id=\(message.id) contentLen=\(content.count) \(ProxyStreamDiagnostics.summarize(data: mergedJSON ?? originalJSON))"
                )
            }

            // The assistant placeholder is created immediately, but the real response can arrive later.
            // Stamp the first received proxy payload time onto the message so bubble timestamps reflect reality.
            if !hadOriginalJSON, existing.role == .assistant, existing.isStreaming {
                existing.timestamp = Date()
            }

            if let proxyEventId = proxyEventId, existing.proxyEventId != proxyEventId {
                existing.proxyEventId = proxyEventId
                // Avoid moving messages while the chat is visible; ExyteChat can mis-render after remove/insert moves.
                // We still persist the proxy event id for delta sync/deduping and rely on append-order stability.
            }
            if isProcessing || isLoadingPreviousSession {
                saveChangesThrottled()
            } else {
                saveChanges()
            }
            messagesRevision += 1
        }
    }

    private func timestampForProxyEventId(
        _ eventId: Int,
        excluding messageId: UUID?,
        fallback: Date?
    ) -> Date {
        let delta: TimeInterval = 0.001
        var lower: Message?
        var upper: Message?

        for message in messages {
            if let messageId, message.id == messageId {
                continue
            }
            guard let otherId = message.proxyEventId else { continue }
            if otherId < eventId {
                if lower == nil || otherId > (lower?.proxyEventId ?? -1) {
                    lower = message
                }
            } else if otherId > eventId {
                if upper == nil || otherId < (upper?.proxyEventId ?? Int.max) {
                    upper = message
                }
            }
        }

        if let lower, let upper {
            let candidate = lower.timestamp.addingTimeInterval(delta)
            let ceiling = upper.timestamp.addingTimeInterval(-delta)
            if candidate < ceiling {
                return candidate
            }
            return lower.timestamp.addingTimeInterval(delta / 2)
        }

        if let lower {
            return lower.timestamp.addingTimeInterval(delta)
        }

        if let upper {
            return upper.timestamp.addingTimeInterval(-delta)
        }

        return fallback ?? Date()
    }

    private func appendOriginalJSON(existing: Data?, new: Data) -> Data? {
        guard let newString = String(data: new, encoding: .utf8) else {
            return existing ?? new
        }
        let trimmedNew = newString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNew.isEmpty else {
            return existing ?? new
        }

        guard let existing = existing,
              let existingString = String(data: existing, encoding: .utf8),
              !existingString.isEmpty else {
            return trimmedNew.data(using: .utf8)
        }

        let existingLines = existingString
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if existingLines.contains(trimmedNew) {
            return existing
        }

        let separator = existingString.hasSuffix("\n") ? "" : "\n"
        let combined = existingString + separator + trimmedNew
        return combined.data(using: .utf8)
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
        if isProcessing || isLoadingPreviousSession {
            saveChangesThrottled()
        } else {
            saveChanges()
        }
    }
    
    /// Save any pending changes, coalescing rapid calls to avoid main-thread stalls.
    private func saveChangesThrottled() {
        guard modelContext != nil else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastSaveTime)
        if elapsed >= saveThrottleInterval {
            saveChanges()
            return
        }

        guard pendingSaveTask == nil else { return }

        let delaySeconds = max(0, saveThrottleInterval - elapsed)
        let delayNanoseconds = UInt64(delaySeconds * 1_000_000_000)
        pendingSaveTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            pendingSaveTask = nil
            saveChanges()
        }
    }

    /// Save any pending changes
    private func saveChanges() {
        guard let modelContext = modelContext else { return }

        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        lastSaveTime = Date()
        
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

    private func handleToolPermissionChunk(_ chunk: MessageChunk, project: RemoteProject) {
        guard let request = toolApprovalRequest(from: chunk, agentId: project.id) else { return }

        toolApprovalStore.recordKnownTool(request.toolName, agentId: project.id)

        guard !handledToolPermissionIds.contains(request.id) else { return }
        handledToolPermissionIds.insert(request.id)

        if let record = toolApprovalStore.decision(for: request.toolName, agentId: project.id) {
            Task { await sendToolApprovalDecision(request: request, decision: record.decision) }
            return
        }

        enqueueToolApproval(request, announce: true)
    }

    func respondToToolApproval(
        _ request: ToolApprovalRequest,
        decision: ToolApprovalDecision,
        scope: ToolApprovalScope
    ) {
        if scope != .once {
            toolApprovalStore.record(
                decision: decision,
                scope: scope,
                toolName: request.toolName,
                agentId: request.agentId
            )
        }

        activeToolApproval = nil
        dequeueNextToolApproval()

        Task { await sendToolApprovalDecision(request: request, decision: decision) }
    }

    func respondToToolApprovalAll(
        _ request: ToolApprovalRequest,
        decision: ToolApprovalDecision
    ) {
        toolApprovalStore.setAgentPolicy(decision, agentId: request.agentId)

        let pending = pendingToolApprovals
        pendingToolApprovals.removeAll { $0.agentId == request.agentId }
        activeToolApproval = nil
        dequeueNextToolApproval()

        Task { await sendToolApprovalDecision(request: request, decision: decision) }
        for pendingRequest in pending where pendingRequest.agentId == request.agentId {
            Task { await sendToolApprovalDecision(request: pendingRequest, decision: decision) }
        }
    }

    private func sendToolApprovalDecision(
        request: ToolApprovalRequest,
        decision: ToolApprovalDecision
    ) async {
        guard let project = ProjectContext.shared.activeProject,
              project.id == request.agentId else { return }

        let message = decision == .deny ? "Permission denied by user." : nil
        do {
            try await claudeService.sendProxyToolPermission(
                project: project,
                permissionId: request.id,
                decision: decision,
                message: message
            )
        } catch {
            await MainActor.run {
                addErrorMessage("Failed to send tool approval for \(request.toolName): \(error.localizedDescription)")
                enqueueToolApproval(request, announce: false, atFront: true)
            }
        }
    }

    private func toolApprovalRequest(from chunk: MessageChunk, agentId: UUID) -> ToolApprovalRequest? {
        guard let metadata = chunk.metadata else { return nil }
        let permissionId = metadata["permissionId"] as? String ?? metadata["permission_id"] as? String
        guard let permissionId, !permissionId.isEmpty else { return nil }

        let toolName = metadata["toolName"] as? String
            ?? metadata["tool_name"] as? String
            ?? "Tool"
        let input = metadata["input"] as? [String: Any] ?? [:]
        let suggestions = metadata["suggestions"] as? [String]
            ?? metadata["permission_suggestions"] as? [String]
            ?? []
        let blockedPath = metadata["blockedPath"] as? String ?? metadata["blocked_path"] as? String

        return ToolApprovalRequest(
            id: permissionId,
            toolName: toolName,
            input: input,
            suggestions: suggestions,
            blockedPath: blockedPath,
            agentId: agentId
        )
    }

    private func enqueueToolApproval(
        _ request: ToolApprovalRequest,
        announce: Bool,
        atFront: Bool = false
    ) {
        if activeToolApproval == nil {
            activeToolApproval = request
        } else if atFront {
            pendingToolApprovals.insert(request, at: 0)
        } else {
            pendingToolApprovals.append(request)
        }

        if announce {
            _ = createMessage(content: "Permission required to use \(request.toolName).", role: .assistant)
        }
    }

    private func dequeueNextToolApproval() {
        guard activeToolApproval == nil, !pendingToolApprovals.isEmpty else { return }
        activeToolApproval = pendingToolApprovals.removeFirst()
    }
    
    /// Remove a message from the chat
    private func removeMessage(_ message: Message) {
        if let modelContext = modelContext {
            modelContext.delete(message)
            saveChanges()
            // Reload messages from database to ensure consistency
            loadMessages()
            messagesRevision += 1
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

    private func normalizeToolResultContent(_ rawContent: Any?) -> String {
        if let content = rawContent as? String {
            return content
        }
        if let blocks = rawContent as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                if let text = block["text"] as? String {
                    return text
                }
                return nil
            }
            if !texts.isEmpty {
                return texts.joined(separator: "\n")
            }
            if let data = try? JSONSerialization.data(withJSONObject: blocks, options: [.prettyPrinted]),
               let string = String(data: data, encoding: .utf8) {
                return string
            }
            return ""
        }
        if let dict = rawContent as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        if let array = rawContent as? [Any],
           let data = try? JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return ""
    }

    private func persistedJSONLine(from chunk: MessageChunk) -> String? {
        guard let metadata = chunk.metadata else { return nil }
        if let normalized = metadata["normalizedJSON"] as? String {
            return canonicalStorageLine(from: normalized) ?? normalized
        }
        if let normalized = normalizedStreamJSONLine(from: metadata) {
            return canonicalStorageLine(from: normalized) ?? normalized
        }
        if let original = metadata["originalJSON"] as? String {
            return canonicalStorageLine(from: original) ?? original
        }
        return nil
    }

    private func canonicalStorageLine(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              JSONSerialization.isValidJSONObject(json),
              let canonicalData = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              let canonical = String(data: canonicalData, encoding: .utf8) else {
            return nil
        }
        return canonical
    }

    private func normalizedStreamJSONLine(from metadata: [String: Any]) -> String? {
        guard let type = metadata["type"] as? String else { return nil }
        guard type == "assistant" || type == "user" else { return nil }
        guard let blocks = metadata["content"] as? [[String: Any]], !blocks.isEmpty else { return nil }

        let role = (metadata["role"] as? String) ?? (type == "user" ? "user" : "assistant")
        let normalized: [String: Any] = [
            "type": type,
            "message": [
                "role": role,
                "content": blocks
            ]
        ]
        return serializeNormalized(normalized)
    }

    private func serializeNormalized(_ json: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private func proxySessionPayload(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
              let json = jsonObject as? [String: Any],
              let type = json["type"] as? String,
              type == "proxy_session" else {
            return nil
        }
        return json
    }

    private func containsProxySessionEvent(in output: String) -> Bool {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            if proxySessionPayload(from: trimmed) != nil {
                return true
            }
        }
        return false
    }

    private func proxyUserJSONLine(for text: String) -> String? {
        guard !text.isEmpty else {
            return nil
        }

        let normalized: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "text",
                        "text": text
                    ]
                ]
            ]
        ]
        return serializeNormalized(normalized)
    }

    private func streamTextContent(from metadata: [String: Any], fallback: String) -> String {
        if let type = metadata["type"] as? String,
           type == "result",
           let result = metadata["result"] as? String,
           !result.isEmpty {
            return result
        }
        if let blocks = metadata["content"] as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard let blockType = block["type"] as? String, blockType == "text" else { return nil }
                return block["text"] as? String
            }
            if !texts.isEmpty {
                return texts.joined(separator: "\n")
            }
        }
        return fallback
    }

    private func isUserPromptEcho(metadata: [String: Any], expectedText: String) -> Bool {
        guard let blocks = metadata["content"] as? [[String: Any]], !blocks.isEmpty else { return false }
        var texts: [String] = []
        for block in blocks {
            guard let blockType = block["type"] as? String, blockType == "text" else { return false }
            guard let text = block["text"] as? String else { return false }
            texts.append(text)
        }
        guard !texts.isEmpty else { return false }
        let combined = texts.joined(separator: "\n")
        return combined.trimmingCharacters(in: .whitespacesAndNewlines) ==
            expectedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func upsertStreamMessage(from chunk: MessageChunk, reuseMessage: Message?, userMessage: Message? = nil) -> Message? {
        guard let metadata = chunk.metadata,
              let jsonLine = persistedJSONLine(from: chunk),
              let jsonData = jsonLine.data(using: .utf8) else { return nil }

        let type = metadata["type"] as? String ?? "unknown"
        let eventId = proxyEventId(from: metadata)
        let hasToolBlocks = metadataContainsToolBlocks(metadata)
        if let agentId = projectId {
            if let tools = metadata["tools"] as? [String] {
                for tool in tools {
                    toolApprovalStore.recordKnownTool(tool, agentId: agentId)
                }
            } else if let tools = metadata["tools"] as? [Any] {
                for entry in tools {
                    guard let tool = entry as? String else { continue }
                    toolApprovalStore.recordKnownTool(tool, agentId: agentId)
                }
            }
            if let toolName = metadata["tool_name"] as? String {
                toolApprovalStore.recordKnownTool(toolName, agentId: agentId)
            }
            if let blocks = metadata["content"] as? [[String: Any]] {
                for block in blocks {
                    guard let blockType = block["type"] as? String, blockType == "tool_use" else { continue }
                    if let name = block["name"] as? String {
                        toolApprovalStore.recordKnownTool(name, agentId: agentId)
                    }
                }
            }
        }
        if type == "user",
           let userMessage,
           isUserPromptEcho(metadata: metadata, expectedText: userMessage.content) {
            updateMessageWithJSON(userMessage, content: userMessage.content, originalJSON: jsonData, proxyEventId: eventId)
            return nil
        }

        if type == "user", !hasToolBlocks, let userMessage, eventId != nil {
            updateMessageWithJSON(userMessage, content: userMessage.content, originalJSON: jsonData, proxyEventId: eventId)
            return nil
        }

        if type == "system" {
            ProxyStreamDiagnostics.log(
                "render skip type=system eventId=\(eventId?.description ?? "nil") \(ProxyStreamDiagnostics.summarize(line: jsonLine))"
            )
            return nil
        }

        if type == "result" {
            ProxyStreamDiagnostics.log(
                "render skip type=result eventId=\(eventId?.description ?? "nil") \(ProxyStreamDiagnostics.summarize(line: jsonLine))"
            )
            return nil
        }

        let isUserMessage = type == "user" && !hasToolBlocks
        let targetMessage = isUserMessage ? nil : reuseMessage

        let content = streamTextContent(from: metadata, fallback: chunk.content)
        ProxyStreamDiagnostics.log(
            "render type=\(type) eventId=\(eventId?.description ?? "nil") reuse=\(reuseMessage != nil) contentLen=\(content.count) \(ProxyStreamDiagnostics.summarize(line: jsonLine))"
        )

        if let message = targetMessage {
            updateMessageWithJSON(message, content: content, originalJSON: jsonData, proxyEventId: eventId)
            message.isStreaming = false
            message.isComplete = true
            return message
        }

        let role: MessageRole = isUserMessage ? .user : .assistant
        let message = createMessage(content: content, role: role, isComplete: true, isStreaming: false, proxyEventId: eventId)
        updateMessageWithJSON(message, content: content, originalJSON: jsonData, proxyEventId: eventId)
        ProxyStreamDiagnostics.log("render created id=\(message.id) role=\(role)")
        return message
    }

    private func messageContainingJSONLine(_ jsonLine: String) -> Message? {
        let canonicalTarget = canonicalStorageLine(from: jsonLine) ?? jsonLine
        for message in messages {
            guard let data = message.originalJSON,
                  let string = String(data: data, encoding: .utf8) else { continue }
            for line in string.split(separator: "\n") {
                let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed == jsonLine {
                    return message
                }
                if let canonical = canonicalStorageLine(from: trimmed), canonical == canonicalTarget {
                    return message
                }
            }
        }
        return nil
    }

    /// Some proxy events echo content we already persisted (e.g. the user's prompt).
    /// In that case, we still need to "apply" the proxy event id to the existing message so ordering stays stable.
    private func applyProxyEventIdToExistingMessageIfPossible(
        jsonLine: String,
        metadata: [String: Any],
        proxyEventId: Int?
    ) -> Bool {
        guard let proxyEventId else { return false }
        guard let jsonData = jsonLine.data(using: .utf8) else { return false }
        guard let message = messageContainingJSONLine(jsonLine) else { return false }

        if message.proxyEventId == proxyEventId {
            return true
        }

        let type = metadata["type"] as? String ?? "unknown"
        let hasToolBlocks = metadataContainsToolBlocks(metadata)
        let isUserMessage = type == "user" && !hasToolBlocks
        let content = isUserMessage ? message.content : streamTextContent(from: metadata, fallback: message.content)
        updateMessageWithJSON(message, content: content, originalJSON: jsonData, proxyEventId: proxyEventId)
        return true
    }

    private func existingStreamJSONLines() -> Set<String> {
        var lines = Set<String>()
        for message in messages {
            guard let data = message.originalJSON,
                  let string = String(data: data, encoding: .utf8) else { continue }
            for line in string.split(separator: "\n") {
                let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    lines.insert(trimmed)
                    if let canonical = canonicalStorageLine(from: trimmed) {
                        lines.insert(canonical)
                    }
                }
            }
        }
        return lines
    }

    private func existingProxyEventIds() -> Set<Int> {
        var ids = Set<Int>()
        for message in messages {
            if let eventId = message.proxyEventId {
                ids.insert(eventId)
            }
        }
        return ids
    }

    /// The proxy emits metadata-only events (e.g. system init/result completion) that we keep for diagnostics
    /// but hide from the chat UI. These should not trigger event-id repair logic.
    private func isProxyMetadataOnlyMessage(_ message: Message) -> Bool {
        if let structured = message.structuredContent,
           structured.type == "system" || structured.type == "result" {
            return true
        }
        if let structuredMessages = message.structuredMessages, !structuredMessages.isEmpty {
            let hasNonMetadata = structuredMessages.contains { content in
                content.type != "system" && content.type != "result"
            }
            return !hasNonMetadata
        }
        return false
    }
    
    /// Check for previous session and recover if needed
    func checkForPreviousSession() async {
        print("📝 checkForPreviousSession: Starting")
        
        // Set a timeout for the entire operation
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds timeout
            await MainActor.run {
                if isLoadingPreviousSession {
                    print("⚠️ checkForPreviousSession: Timeout reached, forcing loading state to false")
                    isLoadingPreviousSession = false
                    showActiveSessionIndicator = false
                }
            }
        }
        
        defer {
            timeoutTask.cancel()
        }
        
        // Ensure we start with loading state true so UI shows feedback
        await MainActor.run {
            isLoadingPreviousSession = true
            print("📝 checkForPreviousSession: Set isLoadingPreviousSession = true")
        }
        guard let project = ProjectContext.shared.activeProject,
              let server = ProjectContext.shared.activeServer else {
            print("📝 Recovery: No active agent or server")
            await MainActor.run {
                isLoadingPreviousSession = false
                showActiveSessionIndicator = false
                print("📝 checkForPreviousSession: Set isLoadingPreviousSession = false (no agent/server)")
            }

            if sessionCheckRetryCount < maxSessionCheckRetries {
                sessionCheckRetryCount += 1
                sessionCheckTask?.cancel()
                sessionCheckTask = Task {
                    let delay = UInt64(sessionCheckRetryDelay * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: delay)
                    await checkForPreviousSession()
                }
            } else {
                hasCheckedForPreviousSession = true
            }
            return
        }

        hasCheckedForPreviousSession = true
        sessionCheckRetryCount = 0
        
        // Check if task was cancelled
        if Task.isCancelled {
            print("📝 Recovery: Task was cancelled")
            await MainActor.run {
                isLoadingPreviousSession = false
                print("📝 checkForPreviousSession: Set isLoadingPreviousSession = false (task cancelled)")
            }
            return
        }

        if claudeService.isProxyChatEnabled {
            await syncProxyHistoryIfNeeded(project: project)
        }
        
        // Check if we have an active streaming message to recover
        guard let messageId = project.activeStreamingMessageId else {
            print("📝 Recovery: No active streaming message ID found")
            // Ensure clean state
            await MainActor.run {
                updateStreamingState(
                    isProcessing: false,
                    clearStreamingMessage: true,
                    streamingBlocks: [],
                    showActiveSessionIndicator: false,
                    isLoadingPreviousSession: false
                )
                print("📝 checkForPreviousSession: Set isLoadingPreviousSession = false (no active streaming message)")
            }
            return
        }

        print("📝 Recovery: Found active streaming message ID: \(messageId)")
        print("📝 Recovery: Current messages count: \(messages.count)")

        if let message = messages.first(where: { $0.id == messageId }) {
            if message.isComplete || !message.isStreaming {
                print("📝 Recovery: Streaming message already complete, clearing active streaming state")
                message.isStreaming = false
                message.isComplete = true
                project.activeStreamingMessageId = nil
                project.updateLastModified()
                saveChanges()
                await MainActor.run {
                    updateStreamingState(
                        isProcessing: false,
                        clearStreamingMessage: true,
                        streamingBlocks: [],
                        showActiveSessionIndicator: false,
                        isLoadingPreviousSession: false
                    )
                }
                return
            }
        }

        let sessionInfo = await claudeService.checkForPreviousSession(
            project: project,
            server: server
        )
        
        print("📝 Recovery: Session check result - hasActiveSession: \(sessionInfo.hasActiveSession), hasOutput: \(sessionInfo.recentOutput != nil), messageId: \(sessionInfo.messageId?.uuidString ?? "nil")")

        if claudeService.isProxyChatEnabled {
            if sessionInfo.hasActiveSession, let recoveryMessageId = sessionInfo.messageId {
                print("📝 Recovery: Proxy session active, resuming streaming")
                showActiveSessionIndicator = true
                await resumeActiveSession(project: project, server: server, messageId: recoveryMessageId)
                showActiveSessionIndicator = false
            } else {
                print("📝 Recovery: Proxy session complete, clearing streaming states")
                updateStreamingState(
                    isProcessing: false,
                    clearStreamingMessage: true,
                    streamingBlocks: [],
                    showActiveSessionIndicator: false
                )
            }
            await MainActor.run {
                isLoadingPreviousSession = false
                print("📝 checkForPreviousSession: Set isLoadingPreviousSession = false (proxy)")
            }
            return
        }
        
        if let recentOutput = sessionInfo.recentOutput,
           !recentOutput.isEmpty,
           let recoveryMessageId = sessionInfo.messageId {
            print("📝 Recovery: Found recent output (\(recentOutput.count) chars) for message ID: \(recoveryMessageId)")

            if containsProxySessionEvent(in: recentOutput) {
                await handleProxySessionSwitch(project: project)
                return
            }
            
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
                    clearStreamingMessage: true,
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

                // Clear active streaming ID since the process is not running
                if project.activeStreamingMessageId == recoveryMessageId {
                    project.activeStreamingMessageId = nil
                    project.updateLastModified()
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

            print("📝 Recovery: No session found; clearing active streaming ID")
            project.activeStreamingMessageId = nil
            project.updateLastModified()
            saveChanges()
        }
        
        // Final ensure loading state is cleared
        await MainActor.run {
            isLoadingPreviousSession = false
            print("📝 checkForPreviousSession: Set isLoadingPreviousSession = false (final)")
        }
        print("📝 checkForPreviousSession: Completed")
    }

    private func syncProxyHistoryIfNeeded(project: RemoteProject) async {
        let now = Date()
        if now < proxySyncNextAttemptAt {
            return
        }
        let syncGeneration = proxySyncGeneration
        let previousVersion = project.proxyVersion
        let previousStartedAt = project.proxyStartedAt
        let previousConversationId = project.proxyConversationId
        let derivedLastEventId = project.proxyLastEventId ?? messages.compactMap { $0.proxyEventId }.max()
        let hadLastEventId = derivedLastEventId != nil
        let hadMessages = !messages.isEmpty
        let since = derivedLastEventId ?? 0

        // If the per-project anchor was lost but we can derive it from persisted messages,
        // write it back before syncing so we don't fall back to a full replay on re-entry.
        if project.proxyLastEventId == nil, let derivedLastEventId {
            project.proxyLastEventId = derivedLastEventId
            project.updateLastModified()
            saveChanges()
        }

        let conversationSuffix = project.proxyConversationId.map { String($0.suffix(6)) } ?? "nil"
        ProxyStreamDiagnostics.log(
            "sync start conv=...\(conversationSuffix) messages=\(messages.count) storedLast=\(String(describing: project.proxyLastEventId)) derivedLast=\(String(describing: derivedLastEventId)) since=\(since)"
        )
        do {
            let (events, info) = try await claudeService.fetchProxyEvents(project: project, since: since)
            guard syncGeneration == proxySyncGeneration else { return }
            proxySyncRetryCount = 0
            proxySyncNextAttemptAt = .distantPast
            showSyncRetryIndicator = false

            if applyUnreadCursorUpdate(from: info, project: project) {
                project.updateLastModified()
                saveChanges()
            }

            let initialBind = previousConversationId == nil && derivedLastEventId != nil
            let conversationChanged = previousConversationId != project.proxyConversationId && !initialBind
            if events.contains(where: { proxySessionPayload(from: $0.jsonLine) != nil }) {
                await handleProxySessionSwitch(project: project)
                return
            }
            var versionChanged = false
            if let version = info.version, version != previousVersion {
                project.proxyVersion = version
                versionChanged = true
            }
            if let startedAt = info.startedAt, startedAt != previousStartedAt {
                project.proxyStartedAt = startedAt
                versionChanged = true
            }
            let conversationIdChanged = previousConversationId != project.proxyConversationId
            if versionChanged || conversationIdChanged {
                project.updateLastModified()
                saveChanges()
            }

            var eventsToApply = events
            // A conversation switch (canonical conversation id changed from a previously known value) means
            // the local cache can be wrong; do a destructive resync in that case.
            //
            // If we don't yet have a stored conversation id (first launch / missing persistence),
            // treat it as an initial bind rather than a conversation change.
            let shouldFullResync = previousConversationId != nil && conversationChanged

            // Only do a repair replay when we have messages but no event id anchor. This should be rare and
            // indicates corrupted local state.
            let shouldRepair = hadMessages && !hadLastEventId

            if shouldFullResync && since != 0 {
                let (fullEvents, _) = try await claudeService.fetchProxyEvents(project: project, since: 0)
                eventsToApply = fullEvents
            }

            if shouldRepair && since != 0 {
                // Non-destructive repair: replay the full conversation and upsert/dedupe locally.
                let (fullEvents, _) = try await claudeService.fetchProxyEvents(project: project, since: 0)
                eventsToApply = fullEvents
            }

            if shouldFullResync {
                resetMessagesForProxySync(project: project)
            }

            guard syncGeneration == proxySyncGeneration else { return }
            guard !eventsToApply.isEmpty else { return }

            for event in eventsToApply {
                if let eventId = event.eventId {
                    project.proxyLastEventId = eventId
                }
            }
            project.updateLastModified()

            let messageId = project.activeStreamingMessageId ?? UUID()
            await applyProxyEvents(eventsToApply, project: project, messageId: messageId)
        } catch {
            if let proxyError = error as? ProxyStreamError,
               case .httpError(let status, let body) = proxyError,
               status == 404,
               body.contains("conversation_unknown") {
                resetMessagesForProxySync(project: project)
                project.proxyConversationId = nil
                project.updateLastModified()
                saveChanges()
                return
            }

            proxySyncRetryCount += 1
            let exponent = Double(max(0, proxySyncRetryCount - 1))
            let backoff = proxySyncBackoffBase * pow(2.0, min(exponent, 3))
            proxySyncNextAttemptAt = Date().addingTimeInterval(backoff)
            if proxySyncRetryCount >= maxProxySyncRetries {
                showSyncRetryIndicator = true
            }
            print("📝 Proxy history sync failed (attempt \(proxySyncRetryCount)): \(error)")
        }
    }

    private func applyUnreadCursorUpdate(from info: ProxyResponseInfo, project: RemoteProject) -> Bool {
        guard let incomingCount = info.renderableAssistantCount, incomingCount >= 0 else { return false }

        let conversationId: String? = {
            guard let id = project.proxyConversationId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty else {
                return nil
            }
            return id
        }()

        let isUnreadStateUninitialized =
            project.unreadConversationId == nil && project.lastKnownUnreadCursor == 0 && project.lastReadUnreadCursor == 0
        if isUnreadStateUninitialized {
            let baseline = min(estimateRenderableBubbleCountForUnreadBaseline(), incomingCount)
            project.lastKnownUnreadCursor = baseline
            project.lastReadUnreadCursor = baseline
        }

        let beforeConversation = project.unreadConversationId
        let beforeKnown = project.lastKnownUnreadCursor
        let beforeRead = project.lastReadUnreadCursor

        if let conversationId {
            if project.unreadConversationId != conversationId {
                let shouldResetReadCursor = project.unreadConversationId != nil && !isUnreadStateUninitialized
                project.unreadConversationId = conversationId
                if shouldResetReadCursor {
                    project.lastReadUnreadCursor = 0
                }
                project.lastKnownUnreadCursor = incomingCount
            } else if incomingCount > project.lastKnownUnreadCursor {
                project.lastKnownUnreadCursor = incomingCount
            }
        } else if incomingCount > project.lastKnownUnreadCursor {
            project.lastKnownUnreadCursor = incomingCount
        }

        return beforeConversation != project.unreadConversationId ||
            beforeKnown != project.lastKnownUnreadCursor ||
            beforeRead != project.lastReadUnreadCursor
    }

    private func estimateRenderableBubbleCountForUnreadBaseline() -> Int {
        var total = 0
        for message in messages {
            guard message.role == .assistant else { continue }

            if let structuredMessages = message.structuredMessages, !structuredMessages.isEmpty {
                for structured in structuredMessages {
                    switch structured.type {
                    case "assistant":
                        total += countRenderableBlocks(in: structured, includeText: true)
                    case "user":
                        total += countRenderableBlocks(in: structured, includeText: false)
                    default:
                        continue
                    }
                }
                continue
            }

            if let structured = message.structuredContent {
                switch structured.type {
                case "assistant":
                    total += countRenderableBlocks(in: structured, includeText: true)
                case "user":
                    total += countRenderableBlocks(in: structured, includeText: false)
                default:
                    break
                }
                continue
            }

            let fallbackBlocks = message.fallbackContentBlocks()
            if !fallbackBlocks.isEmpty {
                total += fallbackBlocks.reduce(0) { partial, block in
                    partial + renderableBlockIncrement(block, includeText: true)
                }
                continue
            }

            if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                total += 1
            }
        }

        return total
    }

    private func countRenderableBlocks(in structured: StructuredMessageContent, includeText: Bool) -> Int {
        guard let content = structured.message else { return 0 }
        switch content.content {
        case .blocks(let blocks):
            return blocks.reduce(0) { partial, block in
                partial + renderableBlockIncrement(block, includeText: includeText)
            }
        case .text(let text):
            guard includeText else { return 0 }
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
        }
    }

    private func renderableBlockIncrement(_ block: ContentBlock, includeText: Bool) -> Int {
        switch block {
        case .text(let textBlock):
            guard includeText else { return 0 }
            return textBlock.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
        case .toolUse, .toolResult:
            return 1
        case .unknown:
            return 0
        }
    }

    private func handleProxySessionSwitch(project: RemoteProject) async {
        resetMessagesForProxySync(project: project)
        hasCheckedForPreviousSession = false
        sessionCheckTask?.cancel()
        isLoadingPreviousSession = false
        showActiveSessionIndicator = false

        sessionCheckTask = Task { @MainActor in
            await syncProxyHistoryIfNeeded(project: project)

            guard let server = ProjectContext.shared.activeServer,
                  let messageId = project.activeStreamingMessageId else {
                return
            }

            showActiveSessionIndicator = true
            await resumeActiveSession(project: project, server: server, messageId: messageId)
            showActiveSessionIndicator = false
        }
    }

    private func resetMessagesForProxySync(project: RemoteProject) {
        guard let modelContext = modelContext else { return }

        for message in messages {
            modelContext.delete(message)
        }

        do {
            try modelContext.save()
        } catch {
            print("Failed to reset messages for proxy sync: \(error)")
        }

        messages.removeAll()
        streamingMessage = nil
        streamingBlocks = []
        isProcessing = false
        streamingRedrawToken = UUID()
        recoveredSessionContent.removeAll()
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        lastSaveTime = .distantPast
        messagesRevision += 1
        activeToolApproval = nil
        pendingToolApprovals = []
        handledToolPermissionIds = []

        project.activeStreamingMessageId = nil
        project.proxyLastEventId = nil
        project.updateLastModified()
        saveChanges()
    }
    
    /// Display recovered conversation from output file
    private func displayRecoveredConversation(_ output: String, project: RemoteProject, messageId: UUID) async {
        let lines = output.components(separatedBy: .newlines)
        var seenLines = existingStreamJSONLines()
        var placeholderMessage = messages.first(where: { $0.id == messageId })
        var lastMessage: Message? = nil
        var lastAssistantMessage: Message? = nil
        var hasResultMessage: Bool
        if let anchor = placeholderMessage {
            hasResultMessage = messages.contains { message in
                message.timestamp >= anchor.timestamp &&
                    (message.structuredMessages?.contains { $0.type == "result" } ?? false)
            }
        } else {
            hasResultMessage = messages.contains { message in
                message.structuredMessages?.contains { $0.type == "result" } ?? false
            }
        }

        for line in lines where !line.isEmpty {
            if line.contains("nohup: ignoring input") {
                continue
            }

            guard let chunk = StreamingJSONParser.parseStreamingLine(line) else { continue }

            if let type = chunk.metadata?["type"] as? String, type == "tool_permission" {
                handleToolPermissionChunk(chunk, project: project)
                continue
            }

            guard let jsonLine = persistedJSONLine(from: chunk) else { continue }

            if seenLines.contains(jsonLine) {
                if let metadata = chunk.metadata {
                    _ = applyProxyEventIdToExistingMessageIfPossible(
                        jsonLine: jsonLine,
                        metadata: metadata,
                        proxyEventId: proxyEventId(from: metadata)
                    )
                }
                continue
            }
            seenLines.insert(jsonLine)

            if let message = upsertStreamMessage(from: chunk, reuseMessage: placeholderMessage) {
                placeholderMessage = nil
                lastMessage = message
                if message.role == .assistant {
                    lastAssistantMessage = message
                }
            }

            if let type = chunk.metadata?["type"] as? String, type == "result" {
                hasResultMessage = true
            }
        }

        if hasResultMessage {
            project.activeStreamingMessageId = nil
        } else if let lastAssistantMessage = lastAssistantMessage {
            project.activeStreamingMessageId = lastAssistantMessage.id
        } else if let lastMessage = lastMessage {
            project.activeStreamingMessageId = lastMessage.id
        }
        project.updateLastModified()
        saveChanges()

        isProcessing = !hasResultMessage
        streamingMessage = nil
        streamingBlocks = []
    }

    private func applyProxyEvents(_ events: [ProxyStreamEvent], project: RemoteProject, messageId: UUID) async {
        let sortedEvents = events.sorted { lhs, rhs in
            switch (lhs.eventId, rhs.eventId) {
            case let (left?, right?):
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return false
            }
        }

        var seenLines = existingStreamJSONLines()
        var seenEventIds = existingProxyEventIds()
        var placeholderMessage = messages.first(where: { $0.id == messageId })
        var lastMessage: Message? = nil
        var lastAssistantMessage: Message? = nil
        var hasResultMessage: Bool

        if let anchor = placeholderMessage {
            hasResultMessage = messages.contains { message in
                message.timestamp >= anchor.timestamp &&
                    (message.structuredMessages?.contains { $0.type == "result" } ?? false)
            }
        } else {
            hasResultMessage = messages.contains { message in
                message.structuredMessages?.contains { $0.type == "result" } ?? false
            }
        }

        for event in sortedEvents {
            if let eventId = event.eventId, seenEventIds.contains(eventId) {
                continue
            }

            guard let chunk = StreamingJSONParser.parseStreamingLine(event.jsonLine) else { continue }
            let enrichedChunk = withProxyEventId(chunk, eventId: event.eventId)

            if let type = enrichedChunk.metadata?["type"] as? String, type == "tool_permission" {
                handleToolPermissionChunk(enrichedChunk, project: project)
                continue
            }

            guard let jsonLine = persistedJSONLine(from: enrichedChunk) else { continue }
            if seenLines.contains(jsonLine) {
                if let metadata = enrichedChunk.metadata {
                    let didApply = applyProxyEventIdToExistingMessageIfPossible(
                        jsonLine: jsonLine,
                        metadata: metadata,
                        proxyEventId: event.eventId
                    )
                    if didApply, let eventId = event.eventId {
                        seenEventIds.insert(eventId)
                    }
                }
                continue
            }

            if let eventId = event.eventId {
                seenEventIds.insert(eventId)
            }
            seenLines.insert(jsonLine)

            if let message = upsertStreamMessage(from: enrichedChunk, reuseMessage: placeholderMessage) {
                placeholderMessage = nil
                lastMessage = message
                if message.role == .assistant {
                    lastAssistantMessage = message
                }
            }

            if let type = enrichedChunk.metadata?["type"] as? String, type == "result" {
                hasResultMessage = true
            }
        }

        if hasResultMessage {
            project.activeStreamingMessageId = nil
        } else if let lastAssistantMessage = lastAssistantMessage {
            project.activeStreamingMessageId = lastAssistantMessage.id
        } else if let lastMessage = lastMessage {
            project.activeStreamingMessageId = lastMessage.id
        }
        project.updateLastModified()
        saveChanges()

        isProcessing = !hasResultMessage
        streamingMessage = nil
        streamingBlocks = []
    }
    
    /// Resume an active session
    private func resumeActiveSession(project: RemoteProject, server: Server, messageId: UUID) async {
        var placeholderMessage = messages.first(where: { $0.id == messageId })
        var didSwitchSession = false

        if placeholderMessage == nil {
            print("📝 Warning: Could not find message with ID \(messageId), creating message for active session")

            let activeMessage = Message(
                content: "",
                role: .assistant,
                projectId: projectId,
                originalJSON: nil,
                isComplete: false,
                isStreaming: true
            )
            activeMessage.id = messageId

            if let modelContext = modelContext {
                modelContext.insert(activeMessage)
                saveChanges()
                loadMessages()
                placeholderMessage = messages.first(where: { $0.id == messageId })
            }

            if placeholderMessage == nil {
                print("❌ Failed to create message for active session recovery")
                showActiveSessionIndicator = false
                return
            }
        }

        streamingMessage = placeholderMessage
        placeholderMessage?.isStreaming = true
        isProcessing = true
        streamingRedrawToken = UUID()
        saveChanges()

        let stream = claudeService.resumeStreamingFromPreviousSession(
            project: project,
            server: server,
            messageId: messageId
        )

        var seenLines = existingStreamJSONLines()

        do {
            for try await chunk in stream {
                saveChangesThrottled()

                if chunk.isError {
                    let errorText = chunk.content.isEmpty ? "Error resuming session." : chunk.content
                    if let placeholder = placeholderMessage {
                        updateMessage(placeholder, with: errorText)
                        placeholder.isStreaming = false
                        placeholder.isComplete = true
                    } else {
                        _ = createMessage(content: errorText, role: .assistant)
                    }
                    placeholderMessage = nil
                    streamingMessage = nil
                    isProcessing = false
                    project.activeStreamingMessageId = nil
                    project.updateLastModified()
                    saveChanges()
                    break
                }

                if let type = chunk.metadata?["type"] as? String, type == "tool_permission" {
                    handleToolPermissionChunk(chunk, project: project)
                    continue
                }

                if let type = chunk.metadata?["type"] as? String, type == "proxy_session" {
                    didSwitchSession = true
                    await handleProxySessionSwitch(project: project)
                    placeholderMessage = nil
                    streamingMessage = nil
                    isProcessing = false
                    break
                }

                guard let jsonLine = persistedJSONLine(from: chunk) else { continue }
                if seenLines.contains(jsonLine) {
                    if let metadata = chunk.metadata {
                        _ = applyProxyEventIdToExistingMessageIfPossible(
                            jsonLine: jsonLine,
                            metadata: metadata,
                            proxyEventId: proxyEventId(from: metadata)
                        )
                    }
                    continue
                }
                seenLines.insert(jsonLine)

                if let message = upsertStreamMessage(from: chunk, reuseMessage: placeholderMessage) {
                    placeholderMessage = nil
                    streamingMessage = nil
                    streamingBlocks = []
                    project.activeStreamingMessageId = message.id
                    project.updateLastModified()
                }

                if let type = chunk.metadata?["type"] as? String, type == "result" {
                    project.activeStreamingMessageId = nil
                    project.updateLastModified()
                    isProcessing = false
                    saveChanges()
                    break
                }
            }
        } catch {
            print("Error resuming stream: \(error)")
            placeholderMessage?.content = "Error resuming session: \(error.localizedDescription)"
            placeholderMessage?.isStreaming = false
            placeholderMessage?.isComplete = true
            isProcessing = false
            project.activeStreamingMessageId = nil
        }

        streamingMessage = nil
        isProcessing = false
        showActiveSessionIndicator = false
        if !didSwitchSession {
            project.activeStreamingMessageId = nil
            project.updateLastModified()
            saveChanges()

            await claudeService.cleanupPreviousSessionFiles(project: project, server: server, messageId: messageId)
        }
    }
}
