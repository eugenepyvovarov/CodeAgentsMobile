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
    static let projectChatDidReset = Notification.Name("projectChatDidReset")
}

enum OpenCodeHydratedMessageMergeAction: Equatable {
    case insert
    case updateExisting
    case skipLocalUserDuplicate
}

enum OpenCodeHydratedMessageMerge {
    static func action(
        for hydrated: CodingAgentRuntimeHydratedMessage,
        existingRuntimeMessageIDs: Set<String>,
        hasLocalUserMessage: Bool
    ) -> OpenCodeHydratedMessageMergeAction {
        if existingRuntimeMessageIDs.contains(hydrated.runtimeMessageID) {
            return .updateExisting
        }
        if hydrated.role == .user, hasLocalUserMessage {
            return .skipLocalUserDuplicate
        }
        return .insert
    }
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
    
    /// Runtime-aware MCP service reference
    private let mcpService = CodingAgentMCPService.shared

    private let runtimeSelectionStore: CodingAgentRuntimeSelectionStore
    private let runtimeRegistry: CodingAgentRuntimeRegistry

    private var mediaPrefetchTasks: [String: Task<Void, Never>] = [:]
    
    /// Loading state for previous session
    var isLoadingPreviousSession = false
    
    /// Active session indicator - shows when resuming a previous session
    var showActiveSessionIndicator = false

    /// Show when proxy sync retries have failed repeatedly
    var showSyncRetryIndicator = false

    /// Set when the selected Claude provider differs from the provider that last successfully ran this chat.
    /// When non-nil, the UI should show a reset banner and sending should be blocked.
    var providerMismatch: ClaudeProviderMismatch?
    
    /// Track if we've already checked for previous session
    private var hasCheckedForPreviousSession = false
    
    /// Track the active session check task
    private var sessionCheckTask: Task<Void, Never>?

    /// Cancellable full-session OpenCode hydration that runs after bounded visible-path recovery.
    private var openCodeFullHydrationTask: Task<Void, Never>?

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

    /// Active OpenCode question request awaiting user input
    var activeOpenCodeQuestion: PendingOpenCodeQuestionRequest?

    /// Queue for additional OpenCode question requests
    private var pendingOpenCodeQuestions: [PendingOpenCodeQuestionRequest] = []

    /// Track handled OpenCode question IDs to avoid duplicate prompts
    private var handledOpenCodeQuestionIds: Set<String> = []

    private let toolApprovalStore = ToolApprovalStore.shared

    private var pendingSaveTask: Task<Void, Never>?
    private var lastSaveTime: Date = .distantPast
    private let saveThrottleInterval: TimeInterval = 0.5

    var isAwaitingToolApproval: Bool {
        activeToolApproval != nil
    }

    var isAwaitingOpenCodeQuestion: Bool {
        activeOpenCodeQuestion != nil
    }
    
    // MARK: - Lifecycle
    
    init(
        runtimeSelectionStore: CodingAgentRuntimeSelectionStore = CodingAgentRuntimeSelectionStore(),
        runtimeRegistry: CodingAgentRuntimeRegistry? = nil
    ) {
        self.runtimeSelectionStore = runtimeSelectionStore
        self.runtimeRegistry = runtimeRegistry ?? CodingAgentRuntimeRegistry()

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
        let timingStart = DispatchTime.now().uptimeNanoseconds
        var timingStatus = ChatRecoveryTiming.Status.complete
        defer {
            ChatRecoveryTiming.log(
                runtime: timingRuntimeName(for: ProjectContext.shared.activeProject),
                projectID: projectId.uuidString,
                operation: "chat.configure",
                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - timingStart,
                metadata: [
                    "localMessages": .count(messages.count),
                    "isProcessing": .flag(isProcessing),
                    "isLoadingPreviousSession": .flag(isLoadingPreviousSession),
                    "status": .status(timingStatus)
                ]
            )
        }

        print("📝 configure: Called with agentId: \(projectId)")

        // SwiftUI may re-enter configuration for the same project/context as the view settles. Treat that as a
        // no-op so we do not restart hydration, MCP fetches, or transient loading state.
        if self.projectId == projectId && self.modelContext === modelContext {
            timingStatus = .skipped
            print("📝 configure: Already configured for same agent, returning")
            return
        }
        
        // Prevent concurrent configuration
        guard !isConfiguring else {
            timingStatus = .skipped
            print("📝 configure: Already configuring, skipping")
            return
        }
        
        isConfiguring = true
        defer { isConfiguring = false }
        
        // Always clear loading states at start to prevent stale UI
        isLoadingPreviousSession = false
        showActiveSessionIndicator = false
        print("📝 configure: Cleared loading states")
        
        // Cancel any existing session check task before resetting
        sessionCheckTask?.cancel()
        sessionCheckTask = nil
        openCodeFullHydrationTask?.cancel()
        openCodeFullHydrationTask = nil
        
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
            activeOpenCodeQuestion = nil
            pendingOpenCodeQuestions = []
            handledOpenCodeQuestionIds = []
            toolApprovalStore.ensureDefaults(for: projectId)
        }
        
        self.modelContext = modelContext
        self.projectId = projectId
        loadMessages()
        let configuredProject = ProjectContext.shared.activeProject
        let runtimeKind = configuredProject.map { activeRuntimeKind(for: $0) } ?? .claudeProxy
        if runtimeKind == .openCode {
            providerMismatch = nil
        } else {
            refreshProviderMismatch(for: configuredProject)
        }

        toolApprovalStore.ensureDefaults(for: projectId)
        
        // Check runtime setup, fetch MCP servers, and ensure project rules when configuring.
        Task {
            if runtimeKind == .claudeProxy, let server = ProjectContext.shared.activeServer {
                _ = await claudeService.checkClaudeInstallation(for: server)
            }
            
            // Fetch MCP servers only if cache is empty
            if cachedMCPServers.isEmpty {
                await fetchMCPServers()
            }

            if let project = ProjectContext.shared.activeProject {
                await claudeService.ensureCodeAgentsUIRulesIfMissing(project: project)
                prefetchCodeAgentsUIMedia(in: project, messages: messages)
            }
        }
        
        // Check for previous session after configuration (only if not already checked)
        if !hasCheckedForPreviousSession {
            // Cancel any existing check
            sessionCheckTask?.cancel()

            // Create new check task
            sessionCheckTask = Task {
                if runtimeKind == .openCode, let project = configuredProject {
                    await hydrateOpenCodeMessagesIfNeeded(project: project)
                } else {
                    await checkForPreviousSession()
                }
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
                guard self.activeRuntimeKind(for: project) == .claudeProxy else {
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

    func refreshProxyEvents(conversationId: String? = nil) async {
        guard let project = ProjectContext.shared.activeProject,
              projectId == project.id,
              modelContext != nil else { return }
        if activeRuntimeKind(for: project) == .openCode {
            if project.applyOpenCodeSessionFromPush(conversationId) {
                saveChanges()
            }
            await hydrateOpenCodeMessagesIfNeeded(project: project)
            return
        }
        guard claudeService.isProxyChatEnabled else { return }
        guard activeRuntimeKind(for: project) == .claudeProxy else { return }
        await syncProxyHistoryIfNeeded(project: project)
    }

    func abortCurrentResponse() async {
        guard let project = ProjectContext.shared.activeProject else { return }
        guard activeRuntimeKind(for: project) == .openCode else { return }

        do {
            try await runtimeRegistry.runtime(for: .openCode).abort(project: project)
        } catch {
            addErrorMessage("Failed to stop OpenCode response: \(error.localizedDescription)")
        }

        if let activeMessageId = project.activeStreamingMessageId,
           let message = messages.first(where: { $0.id == activeMessageId }) {
            if message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updateMessage(message, with: "[Response stopped]")
            }
            message.isStreaming = false
            message.isComplete = true
        }

        project.activeStreamingMessageId = nil
        project.updateLastModified()
        streamingMessage = nil
        streamingBlocks = []
        isProcessing = false
        showActiveSessionIndicator = false
        saveChanges()
    }
    
    /// Send a message to Claude
    /// - Parameter text: The message text
    func sendMessage(_ text: String) async {
        guard let project = ProjectContext.shared.activeProject else {
            addErrorMessage("No active agent. Please select an agent first.")
            return
        }

        if activeRuntimeKind(for: project) == .openCode {
            await sendOpenCodeMessage(text, project: project)
            return
        }

        refreshProviderMismatch(for: project)
        if providerMismatch != nil {
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
            do {
                _ = try await AgentIdentityService.shared.ensureAgentId(for: project, modelContext: context)
            } catch {
                SSHLogger.log("Failed to ensure agent id for project \(project.id): \(error)", level: .warning)
            }
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

                    if !chunk.isError {
                        project.lastSuccessfulClaudeProviderRawValue = ClaudeProviderMismatchGuard.currentProvider().rawValue
                    }

                    project.activeStreamingMessageId = nil
                    project.updateLastModified()
                    isProcessing = false
                    streamingMessage = nil
                    streamingBlocks = []
                    refreshProviderMismatch(for: project)
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

    private func sendOpenCodeMessage(_ text: String, project: RemoteProject) async {
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

        if let previousStreaming = messages.last(where: { $0.isStreaming }) {
            previousStreaming.isStreaming = false
            previousStreaming.isComplete = true
            if previousStreaming.content.isEmpty && previousStreaming.originalJSON == nil {
                updateMessage(previousStreaming, with: "[Response was interrupted by new message]")
            }
            saveChanges()
        }

        streamingMessage = nil
        streamingBlocks = []
        isProcessing = false
        saveChanges()

        _ = createMessage(content: text, role: .user)
        let assistantMessage = createMessage(content: "", role: .assistant, isComplete: false, isStreaming: true)
        streamingMessage = assistantMessage
        streamingRedrawToken = UUID()
        isProcessing = true

        project.selectedAgentRuntime = .openCode
        project.activeStreamingMessageId = assistantMessage.id
        project.updateLastModified()
        saveChanges()

        do {
            let runtime = runtimeRegistry.runtime(for: .openCode)
            let stream = runtime.sendMessage(text, in: project, messageId: assistantMessage.id, mcpServers: cachedMCPServers)
            var didReceiveAnswerText = false
            var didReceiveProgress = false
            var toolMessagesByPartID: [String: Message] = [:]
            var textMessagesByPartID: [String: Message] = [:]
            var textMessagesByMessageID: [String: Message] = [:]
            var assistantMessageIsTransientProgress = false
            var assistantMessageWasRemoved = false

            for try await chunk in stream {
                let chunkType = chunk.metadata?["type"] as? String

                if chunkType == "tool_permission" {
                    handleToolPermissionChunk(chunk, project: project)
                    continue
                }

                if chunkType == "opencode_question" {
                    didReceiveProgress = true
                    handleOpenCodeQuestionChunk(chunk, project: project)
                    continue
                }

                if chunkType == "opencode_tool" {
                    didReceiveProgress = true
                    let partID = chunk.metadata?["toolPartID"] as? String ?? UUID().uuidString
                    let toolMessage: Message
                    if let existing = toolMessagesByPartID[partID] {
                        toolMessage = existing
                    } else {
                        toolMessage = createMessage(
                            content: chunk.content,
                            role: .assistant,
                            isComplete: chunk.isComplete,
                            isStreaming: !chunk.isComplete
                        )
                        toolMessagesByPartID[partID] = toolMessage
                    }
                    project.activeStreamingMessageId = toolMessage.id

                    let originalJSON = (chunk.metadata?["originalJSON"] as? String)?.data(using: .utf8)
                    updateMessageWithJSON(
                        toolMessage,
                        content: chunk.content,
                        originalJSON: originalJSON,
                        replaceOriginalJSON: true
                    )
                    toolMessage.isStreaming = !chunk.isComplete
                    toolMessage.isComplete = chunk.isComplete

                    if let provider = chunk.metadata?["runtimeProvider"] as? String {
                        project.lastSuccessfulRuntimeProviderRawValue = provider
                    }
                    continue
                }

                if chunkType == "opencode_progress" {
                    didReceiveProgress = true
                    guard !didReceiveAnswerText else {
                        continue
                    }
                    updateMessage(assistantMessage, with: chunk.content)
                    assistantMessage.isStreaming = true
                    assistantMessage.isComplete = false
                    assistantMessageIsTransientProgress = true
                    project.activeStreamingMessageId = assistantMessage.id
                    if let provider = chunk.metadata?["runtimeProvider"] as? String {
                        project.lastSuccessfulRuntimeProviderRawValue = provider
                    }
                    continue
                }

                if chunk.isError {
                    let errorText = chunk.content.isEmpty ? "OpenCode failed to respond." : chunk.content
                    updateMessage(assistantMessage, with: errorText)
                    assistantMessage.isStreaming = false
                    assistantMessage.isComplete = true
                    didReceiveAnswerText = true
                    break
                }

                if !chunk.content.isEmpty {
                    let messageID = chunk.metadata?["opencodeMessageId"] as? String
                    let partID = chunk.metadata?["opencodeCurrentPartId"] as? String
                    let targetMessage: Message
                    if let messageID, let existing = textMessagesByMessageID[messageID] {
                        targetMessage = existing
                    } else if let partID, let existing = textMessagesByPartID[partID] {
                        targetMessage = existing
                    } else if !didReceiveAnswerText && !didReceiveProgress && assistantMessage.content.isEmpty {
                        targetMessage = assistantMessage
                    } else {
                        targetMessage = createMessage(
                            content: "",
                            role: .assistant,
                            isComplete: false,
                            isStreaming: true
                        )
                    }
                    if let messageID {
                        textMessagesByMessageID[messageID] = targetMessage
                    }
                    if let partID {
                        textMessagesByPartID[partID] = targetMessage
                    }
                    updateOpenCodeMessage(targetMessage, with: chunk)
                    project.activeStreamingMessageId = targetMessage.id
                    didReceiveAnswerText = true
                    if targetMessage.id != assistantMessage.id,
                       assistantMessageIsTransientProgress || assistantMessage.content.isEmpty {
                        removeTransientOpenCodeMessage(assistantMessage)
                        assistantMessageIsTransientProgress = false
                        assistantMessageWasRemoved = true
                    }
                }

                if let provider = chunk.metadata?["runtimeProvider"] as? String {
                    project.lastSuccessfulRuntimeProviderRawValue = provider
                }

                if chunk.isComplete {
                    if let partID = chunk.metadata?["opencodeCurrentPartId"] as? String,
                       let completedTextMessage = textMessagesByPartID[partID] {
                        completedTextMessage.isStreaming = false
                        completedTextMessage.isComplete = true
                    } else if let messageID = chunk.metadata?["opencodeMessageId"] as? String,
                              let completedTextMessage = textMessagesByMessageID[messageID] {
                        completedTextMessage.isStreaming = false
                        completedTextMessage.isComplete = true
                    } else if !assistantMessageWasRemoved {
                        assistantMessage.isStreaming = false
                        assistantMessage.isComplete = true
                    } else {
                        project.activeStreamingMessageId = nil
                    }
                    break
                }
            }

            if !didReceiveAnswerText {
                let fallback = didReceiveProgress
                    ? "OpenCode ran steps but did not return a final message."
                    : "OpenCode finished without returning text."
                updateMessage(assistantMessage, with: fallback)
            }

            for toolMessage in toolMessagesByPartID.values {
                toolMessage.isStreaming = false
                toolMessage.isComplete = true
            }
            for textMessage in textMessagesByPartID.values {
                textMessage.isStreaming = false
                textMessage.isComplete = true
            }
            if !assistantMessageWasRemoved {
                assistantMessage.isStreaming = false
                assistantMessage.isComplete = true
            }
            project.activeStreamingMessageId = nil
            project.updateLastModified()
            saveChanges()
        } catch {
            let errorText = "Failed to get OpenCode response: \(error.localizedDescription)"
            updateMessage(assistantMessage, with: errorText)
            assistantMessage.isStreaming = false
            assistantMessage.isComplete = true
            project.activeStreamingMessageId = nil
            project.updateLastModified()
            saveChanges()
        }

        streamingMessage = nil
        streamingBlocks = []
        isProcessing = false
    }

    func refreshProviderMismatch(for project: RemoteProject?) {
        if let project, activeRuntimeKind(for: project) == .openCode {
            providerMismatch = nil
            return
        }
        providerMismatch = ClaudeProviderMismatchGuard.mismatch(for: project)
    }

    func reloadMessages() {
        loadMessages()
        if let project = ProjectContext.shared.activeProject,
           activeRuntimeKind(for: project) == .openCode {
            providerMismatch = nil
        } else {
            refreshProviderMismatch(for: ProjectContext.shared.activeProject)
        }
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
        if let project = ProjectContext.shared.activeProject {
            project.lastSuccessfulClaudeProviderRawValue = nil
        }
        providerMismatch = nil
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
        activeOpenCodeQuestion = nil
        pendingOpenCodeQuestions = []
        handledOpenCodeQuestionIds = []
        proxySyncRetryCount = 0
        proxySyncNextAttemptAt = .distantPast
        showSyncRetryIndicator = false
        
        // Clear active streaming message ID when clearing chat
        if let project = ProjectContext.shared.activeProject {
            let previousProxyConversationId = project.proxyConversationId
            let previousProxyConversationGroupId = project.proxyConversationGroupId
            let previousProxyLastEventId = project.proxyLastEventId

            project.activeStreamingMessageId = nil
            if activeRuntimeKind(for: project) == .openCode {
                project.resetOpenCodeRuntimeState()
                Task { @MainActor in
                    do {
                        try await ProxyTaskService.shared.clearActiveOpenCodeSession(project: project)
                    } catch {
                        SSHLogger.log("Failed to clear active OpenCode task session for project \(project.id): \(error)", level: .warning)
                    }
                }
            } else if claudeService.isProxyChatEnabled {
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
        activeOpenCodeQuestion = nil
        pendingOpenCodeQuestions = []
        handledOpenCodeQuestionIds = []
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
        isLoadingPreviousSession = false
        showActiveSessionIndicator = false
        showSyncRetryIndicator = false
        proxySyncRetryCount = 0
        proxySyncNextAttemptAt = .distantPast
        activeToolApproval = nil
        pendingToolApprovals = []
        handledToolPermissionIds = []
        activeOpenCodeQuestion = nil
        pendingOpenCodeQuestions = []
        handledOpenCodeQuestionIds = []
        
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

        let timingStart = DispatchTime.now().uptimeNanoseconds
        var fetchedCount = cachedMCPServers.count
        var connectedCount = cachedMCPServers.filter { $0.status == .connected }.count
        var timingStatus = ChatRecoveryTiming.Status.complete
        defer {
            ChatRecoveryTiming.log(
                runtime: timingRuntimeName(for: project),
                projectID: project.id.uuidString,
                operation: "chat.fetchMCPServers",
                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - timingStart,
                metadata: [
                    "cachedServers": .count(cachedMCPServers.count),
                    "connectedServers": .count(connectedCount),
                    "fetchedServers": .count(fetchedCount),
                    "status": .status(timingStatus)
                ]
            )
        }
        
        do {
            cachedMCPServers = try await mcpService.fetchServers(for: project)
            fetchedCount = cachedMCPServers.count
            print("📝 Fetched and cached \(cachedMCPServers.count) MCP servers")
            
            // Log connected servers
            let connectedServers = cachedMCPServers.filter { $0.status == .connected }
            connectedCount = connectedServers.count
            print("📝 Connected MCP servers: \(connectedServers.map { $0.name }.joined(separator: ", "))")
        } catch {
            timingStatus = .failed
            print("⚠️ Failed to fetch MCP servers: \(error)")
            cachedMCPServers = []
            fetchedCount = 0
            connectedCount = 0
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

    private func activeRuntimeKind(for project: RemoteProject) -> CodingAgentRuntimeKind {
        CodingAgentRuntimeResolver.runtimeKind(for: project, selectionStore: runtimeSelectionStore)
    }

    private func timingRuntimeName(for project: RemoteProject?) -> String {
        guard let project else { return CodingAgentRuntimeKind.claudeProxy.rawValue }
        return activeRuntimeKind(for: project).rawValue
    }

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

        let timingStart = DispatchTime.now().uptimeNanoseconds
        var fetchedCount = 0
        var repairedStreamingCount = 0
        var restoredStreamingCount = 0
        var timingStatus = ChatRecoveryTiming.Status.complete
        defer {
            ChatRecoveryTiming.log(
                runtime: timingRuntimeName(for: ProjectContext.shared.activeProject),
                projectID: projectId.uuidString,
                operation: "chat.loadMessages",
                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - timingStart,
                metadata: [
                    "fetchedMessages": .count(fetchedCount),
                    "localMessages": .count(messages.count),
                    "repairedStreamingMessages": .count(repairedStreamingCount),
                    "restoredStreamingMessages": .count(restoredStreamingCount),
                    "status": .status(timingStatus)
                ]
            )
        }
        
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { message in
                message.projectId == projectId
            },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        
        do {
            let fetched = try modelContext.fetch(descriptor)
            fetchedCount = fetched.count
            messages = fetched.sorted { isMessageBefore($0, $1) }

            // Keep the per-project proxy event anchor in sync with persisted messages so re-opening the chat
            // continues from deltas instead of replaying the full history.
            if claudeService.isProxyChatEnabled,
               let project = ProjectContext.shared.activeProject,
               project.id == projectId {
                if let usableEventAnchor = ProxyEventRecovery.usableAnchor(project: project, messages: messages),
                   ProxyEventRecovery.advanceLastEventId(project: project, to: usableEventAnchor) {
                    project.updateLastModified()
                    saveChanges()
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
                    repairedStreamingCount += 1
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
                    restoredStreamingCount += 1
                    
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
            timingStatus = .failed
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
        proxyEventId: Int? = nil,
        timestamp: Date? = nil
    ) -> Message {
        let message = Message(content: content, role: role, projectId: projectId, originalJSON: nil, isComplete: isComplete, isStreaming: isStreaming)
        message.proxyEventId = proxyEventId

        if let timestamp {
            message.timestamp = timestamp
        } else if role == .assistant {
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
    private func updateMessageWithJSON(
        _ message: Message,
        content: String,
        originalJSON: Data?,
        proxyEventId: Int? = nil,
        replaceOriginalJSON: Bool = false
    ) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            let existing = messages[index]
            let hadOriginalJSON = existing.originalJSON != nil
            existing.content = content
            if let originalJSON = originalJSON {
                let mergedJSON = replaceOriginalJSON
                    ? normalizedOriginalJSONLine(from: originalJSON)
                    : appendOriginalJSON(existing: existing.originalJSON, new: originalJSON)
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

    private func updateOpenCodeMessage(_ message: Message, with chunk: MessageChunk) {
        let originalJSON = (chunk.metadata?["originalJSON"] as? String)?.data(using: .utf8)
        let content = chunk.content.isEmpty ? message.content : chunk.content
        updateMessageWithJSON(message, content: content, originalJSON: originalJSON, replaceOriginalJSON: true)
        message.isStreaming = !chunk.isComplete
        message.isComplete = chunk.isComplete

        if chunk.isComplete, let project = ProjectContext.shared.activeProject {
            prefetchCodeAgentsUIMedia(in: project, messages: [message])
        }
    }

    private func updateOpenCodeMessage(_ message: Message, with hydrated: CodingAgentRuntimeHydratedMessage) {
        updateMessageWithJSON(
            message,
            content: hydrated.text.isEmpty ? message.content : hydrated.text,
            originalJSON: hydrated.originalPayload,
            replaceOriginalJSON: true
        )
        message.isStreaming = false
        message.isComplete = true
    }

    private func hydrateOpenCodeMessagesIfNeeded(project: RemoteProject) async {
        guard activeRuntimeKind(for: project) == .openCode else { return }
        guard project.openCodeSessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }

        do {
            let runtime = runtimeRegistry.runtime(for: .openCode)
            let sessionStateStart = DispatchTime.now().uptimeNanoseconds
            let sessionState: CodingAgentRuntimeSessionState
            do {
                sessionState = try await runtime.sessionState(for: project)
                ChatRecoveryTiming.log(
                    runtime: CodingAgentRuntimeKind.openCode.rawValue,
                    projectID: project.id.uuidString,
                    operation: "opencode.sessionState",
                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - sessionStateStart,
                    metadata: [
                        "localMessages": .count(messages.count),
                        "sessionStatus": .status(timingStatus(for: sessionState.status)),
                        "status": .status(.complete)
                    ]
                )
            } catch {
                ChatRecoveryTiming.log(
                    runtime: CodingAgentRuntimeKind.openCode.rawValue,
                    projectID: project.id.uuidString,
                    operation: "opencode.sessionState",
                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - sessionStateStart,
                    metadata: [
                        "localMessages": .count(messages.count),
                        "status": .status(.failed)
                    ]
                )
                throw error
            }

            let showVisibleRecovery: Bool
            switch sessionState.status {
            case .busy, .retrying:
                showVisibleRecovery = true
            case .idle, .unknown:
                showVisibleRecovery = false
            }
            if showVisibleRecovery {
                isLoadingPreviousSession = true
            }
            defer {
                if showVisibleRecovery {
                    isLoadingPreviousSession = false
                }
            }

            let hydrateStart = DispatchTime.now().uptimeNanoseconds
            let hydrationResult: OpenCodeHydrationResult
            do {
                hydrationResult = try await runtime.hydrateMessages(for: project, mode: .initialBounded())
                ChatRecoveryTiming.log(
                    runtime: CodingAgentRuntimeKind.openCode.rawValue,
                    projectID: project.id.uuidString,
                    operation: "opencode.hydrateMessages.\(hydrationResult.mode.timingName)",
                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - hydrateStart,
                    metadata: [
                        "fetchedMessages": .count(hydrationResult.fetchedCount),
                        "hydratedMessages": .count(hydrationResult.hydratedMessages.count),
                        "localMessages": .count(messages.count),
                        "selectedMessages": .count(hydrationResult.selectedCount),
                        "status": .status(.complete)
                    ]
                )
            } catch {
                ChatRecoveryTiming.log(
                    runtime: CodingAgentRuntimeKind.openCode.rawValue,
                    projectID: project.id.uuidString,
                    operation: "opencode.hydrateMessages.initialBounded",
                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - hydrateStart,
                    metadata: [
                        "localMessages": .count(messages.count),
                        "status": .status(.failed)
                    ]
                )
                throw error
            }
            applyOpenCodeHydrationResult(hydrationResult, project: project)

            reconcileOpenCodeSessionState(sessionState, project: project)
            ChatRecoveryTiming.measure(
                runtime: CodingAgentRuntimeKind.openCode.rawValue,
                projectID: project.id.uuidString,
                operation: "opencode.mediaPrefetch",
                metadata: ["localMessages": .count(messages.count)]
            ) {
                prefetchCodeAgentsUIMedia(in: project, messages: messages)
            }
            project.updateLastModified()
            ChatRecoveryTiming.measure(
                runtime: CodingAgentRuntimeKind.openCode.rawValue,
                projectID: project.id.uuidString,
                operation: "opencode.finalSave",
                metadata: ["localMessages": .count(messages.count)]
            ) {
                saveChanges()
            }
            scheduleOpenCodeFullHydrationIfNeeded(initialResult: hydrationResult, project: project)
        } catch {
            print("📝 OpenCode hydration failed: \(error)")
            showActiveSessionIndicator = false
        }
    }

    private func scheduleOpenCodeFullHydrationIfNeeded(
        initialResult: OpenCodeHydrationResult,
        project: RemoteProject
    ) {
        guard case .initialBounded(let limit) = initialResult.mode,
              initialResult.fetchedCount >= limit else { return }

        openCodeFullHydrationTask?.cancel()
        openCodeFullHydrationTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            guard self.projectId == project.id, self.modelContext != nil else { return }
            do {
                let runtime = self.runtimeRegistry.runtime(for: .openCode)
                let hydrateStart = DispatchTime.now().uptimeNanoseconds
                let result = try await runtime.hydrateMessages(for: project, mode: .fullRefresh)
                guard !Task.isCancelled else { return }
                ChatRecoveryTiming.log(
                    runtime: CodingAgentRuntimeKind.openCode.rawValue,
                    projectID: project.id.uuidString,
                    operation: "opencode.hydrateMessages.\(result.mode.timingName)",
                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - hydrateStart,
                    metadata: [
                        "fetchedMessages": .count(result.fetchedCount),
                        "hydratedMessages": .count(result.hydratedMessages.count),
                        "localMessages": .count(self.messages.count),
                        "selectedMessages": .count(result.selectedCount),
                        "status": .status(.complete)
                    ]
                )
                self.applyOpenCodeHydrationResult(result, project: project)
                self.prefetchCodeAgentsUIMedia(in: project, messages: self.messages)
                project.updateLastModified()
                self.saveChanges()
            } catch is CancellationError {
                ChatRecoveryTiming.log(
                    runtime: CodingAgentRuntimeKind.openCode.rawValue,
                    projectID: project.id.uuidString,
                    operation: "opencode.hydrateMessages.fullRefresh",
                    elapsedNanoseconds: 0,
                    metadata: ["status": .status(.cancelled)]
                )
            } catch {
                ChatRecoveryTiming.log(
                    runtime: CodingAgentRuntimeKind.openCode.rawValue,
                    projectID: project.id.uuidString,
                    operation: "opencode.hydrateMessages.fullRefresh",
                    elapsedNanoseconds: 0,
                    metadata: [
                        "localMessages": .count(self.messages.count),
                        "status": .status(.failed)
                    ]
                )
            }
        }
    }

    private func applyOpenCodeHydrationResult(_ result: OpenCodeHydrationResult, project: RemoteProject) {
        var existingRuntimeMessageIDs = openCodeRuntimeMessageIDs(in: messages)
        var skippedDuplicateMessages = 0
        var skippedLocalUserMessages = 0
        var insertedMessages = 0
        var updatedMessages = 0
        let existingRuntimeMessageCount = existingRuntimeMessageIDs.count
        let dedupeStart = DispatchTime.now().uptimeNanoseconds
        for hydrated in result.hydratedMessages {
            let mergeAction = OpenCodeHydratedMessageMerge.action(
                for: hydrated,
                existingRuntimeMessageIDs: existingRuntimeMessageIDs,
                hasLocalUserMessage: hasLocalUserMessage(matching: hydrated.text)
            )
            switch mergeAction {
            case .updateExisting:
                if let existingMessage = messages.first(where: { openCodeRuntimeMessageID(from: $0) == hydrated.runtimeMessageID }) {
                    updateOpenCodeMessage(existingMessage, with: hydrated)
                    updatedMessages += 1
                } else {
                    skippedDuplicateMessages += 1
                }
                continue
            case .skipLocalUserDuplicate:
                skippedLocalUserMessages += 1
                continue
            case .insert:
                break
            }

            let message = createMessage(content: hydrated.text, role: hydrated.role, timestamp: hydrated.createdAt)
            if let originalPayload = hydrated.originalPayload {
                updateMessageWithJSON(message, content: hydrated.text, originalJSON: originalPayload, replaceOriginalJSON: true)
            }
            existingRuntimeMessageIDs.insert(hydrated.runtimeMessageID)
            insertedMessages += 1
        }
        ChatRecoveryTiming.log(
            runtime: CodingAgentRuntimeKind.openCode.rawValue,
            projectID: project.id.uuidString,
            operation: "opencode.hydration.dedupeInsert.\(result.mode.timingName)",
            elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - dedupeStart,
            metadata: [
                "existingRuntimeMessages": .count(existingRuntimeMessageCount),
                "finalLocalMessages": .count(messages.count),
                "hydratedMessages": .count(result.hydratedMessages.count),
                "insertedMessages": .count(insertedMessages),
                "localMessages": .count(messages.count - insertedMessages),
                "skippedDuplicateMessages": .count(skippedDuplicateMessages),
                "skippedLocalUserMessages": .count(skippedLocalUserMessages),
                "updatedMessages": .count(updatedMessages),
                "status": .status(.complete)
            ]
        )
    }

    private func timingStatus(for sessionStatus: CodingAgentRuntimeSessionState.Status) -> ChatRecoveryTiming.Status {
        switch sessionStatus {
        case .idle:
            return .inactive
        case .busy, .retrying:
            return .active
        case .unknown:
            return .unknown
        }
    }

    private func reconcileOpenCodeSessionState(_ state: CodingAgentRuntimeSessionState, project: RemoteProject) {
        switch state.status {
        case .busy, .retrying:
            showActiveSessionIndicator = true
            isProcessing = true
            if let assistant = messages.last(where: { $0.role == .assistant }) {
                assistant.isStreaming = true
                assistant.isComplete = false
                streamingMessage = assistant
                streamingRedrawToken = UUID()
                project.activeStreamingMessageId = assistant.id
            }
        case .idle, .unknown:
            showActiveSessionIndicator = false
            isProcessing = false
            streamingMessage = nil
            streamingBlocks = []
            for message in messages where message.isStreaming {
                message.isStreaming = false
                message.isComplete = true
            }
            project.activeStreamingMessageId = nil
        }
    }

    private func openCodeRuntimeMessageIDs(in messages: [Message]) -> Set<String> {
        Set(messages.compactMap(openCodeRuntimeMessageID(from:)))
    }

    private func openCodeRuntimeMessageID(from message: Message) -> String? {
        guard let originalJSON = message.originalJSON,
              let raw = String(data: originalJSON, encoding: .utf8) else {
            return nil
        }

        for line in raw.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let opencode = json["opencode"] as? [String: Any],
                  let messageID = opencode["messageID"] as? String,
                  !messageID.isEmpty else {
                continue
            }
            return messageID
        }

        return nil
    }

    private func hasLocalUserMessage(matching text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return messages.contains { message in
            message.role == .user &&
                message.content.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
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

    private func normalizedOriginalJSONLine(from data: Data) -> Data? {
        guard let string = String(data: data, encoding: .utf8) else {
            return data
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return data
        }
        return trimmed.data(using: .utf8)
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

        let timingStart = DispatchTime.now().uptimeNanoseconds
        var timingStatus = ChatRecoveryTiming.Status.complete
        defer {
            ChatRecoveryTiming.log(
                runtime: timingRuntimeName(for: ProjectContext.shared.activeProject),
                projectID: projectId?.uuidString,
                operation: "chat.saveChanges",
                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - timingStart,
                metadata: [
                    "isLoadingPreviousSession": .flag(isLoadingPreviousSession),
                    "isProcessing": .flag(isProcessing),
                    "localMessages": .count(messages.count),
                    "status": .status(timingStatus)
                ]
            )
        }

        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        lastSaveTime = Date()
        
        do {
            try modelContext.save()
        } catch {
            timingStatus = .failed
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
            Task { await sendToolApprovalDecision(request: request, decision: record.decision, scope: record.scope) }
            return
        }

        enqueueToolApproval(request, announce: true)
    }

    private func handleOpenCodeQuestionChunk(_ chunk: MessageChunk, project: RemoteProject) {
        guard let request = openCodeQuestionRequest(from: chunk) else { return }
        guard !handledOpenCodeQuestionIds.contains(request.id) else { return }
        handledOpenCodeQuestionIds.insert(request.id)

        enqueueOpenCodeQuestion(
            PendingOpenCodeQuestionRequest(request: request, agentId: project.id),
            announce: true
        )
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

        Task { await sendToolApprovalDecision(request: request, decision: decision, scope: scope) }
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

        Task { await sendToolApprovalDecision(request: request, decision: decision, scope: .agent) }
        for pendingRequest in pending where pendingRequest.agentId == request.agentId {
            Task { await sendToolApprovalDecision(request: pendingRequest, decision: decision, scope: .agent) }
        }
    }

    func respondToOpenCodeQuestion(
        _ pendingRequest: PendingOpenCodeQuestionRequest,
        answers: [[String]]
    ) {
        activeOpenCodeQuestion = nil
        dequeueNextOpenCodeQuestion()

        Task { await sendOpenCodeQuestionReply(pendingRequest: pendingRequest, answers: answers) }
    }

    func rejectOpenCodeQuestion(_ pendingRequest: PendingOpenCodeQuestionRequest) {
        activeOpenCodeQuestion = nil
        dequeueNextOpenCodeQuestion()

        Task { await sendOpenCodeQuestionReject(pendingRequest: pendingRequest) }
    }

    private func sendToolApprovalDecision(
        request: ToolApprovalRequest,
        decision: ToolApprovalDecision,
        scope: ToolApprovalScope = .once
    ) async {
        guard let project = ProjectContext.shared.activeProject,
              project.id == request.agentId else { return }

        let message = decision == .deny ? "Permission denied by user." : nil
        do {
            if activeRuntimeKind(for: project) == .openCode {
                try await runtimeRegistry.runtime(for: .openCode).replyToPermission(
                    project: project,
                    permissionId: request.id,
                    decision: decision,
                    scope: scope,
                    message: message
                )
            } else {
                try await claudeService.sendProxyToolPermission(
                    project: project,
                    permissionId: request.id,
                    decision: decision,
                    message: message
                )
            }
        } catch {
            await MainActor.run {
                if let proxyError = error as? ProxyStreamError, proxyError.isPermissionNotFound {
                    addErrorMessage(
                        "Tool approval expired (permission no longer active on proxy). Please retry the request."
                    )
                    return
                }

                let errorDescription: String
                if let proxyError = error as? ProxyStreamError {
                    errorDescription = proxyError.proxyErrorMessage ?? proxyError.localizedDescription
                } else {
                    errorDescription = error.localizedDescription
                }

                addErrorMessage("Failed to send tool approval for \(request.toolName): \(errorDescription)")
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

    private func openCodeQuestionRequest(from chunk: MessageChunk) -> OpenCodeQuestionRequest? {
        guard let metadata = chunk.metadata else { return nil }
        if let request = metadata["questionRequest"] as? OpenCodeQuestionRequest {
            return request.id.isEmpty || request.questions.isEmpty ? nil : request
        }

        guard let questionId = metadata["questionId"] as? String, !questionId.isEmpty else { return nil }
        let questionText = chunk.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !questionText.isEmpty else { return nil }
        return OpenCodeQuestionRequest(
            id: questionId,
            sessionID: metadata["opencodeSessionId"] as? String,
            questions: [
                OpenCodeQuestion(
                    header: "Question",
                    question: questionText,
                    options: [],
                    custom: true
                )
            ]
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

    private func enqueueOpenCodeQuestion(
        _ pendingRequest: PendingOpenCodeQuestionRequest,
        announce: Bool,
        atFront: Bool = false
    ) {
        if activeOpenCodeQuestion == nil {
            activeOpenCodeQuestion = pendingRequest
        } else if atFront {
            pendingOpenCodeQuestions.insert(pendingRequest, at: 0)
        } else {
            pendingOpenCodeQuestions.append(pendingRequest)
        }

        if announce,
           let question = pendingRequest.request.questions.first?.question.trimmingCharacters(in: .whitespacesAndNewlines),
           !question.isEmpty {
            _ = createMessage(content: "Question required: \(question)", role: .assistant)
        }
    }

    private func dequeueNextToolApproval() {
        guard activeToolApproval == nil, !pendingToolApprovals.isEmpty else { return }
        activeToolApproval = pendingToolApprovals.removeFirst()
    }

    private func dequeueNextOpenCodeQuestion() {
        guard activeOpenCodeQuestion == nil, !pendingOpenCodeQuestions.isEmpty else { return }
        activeOpenCodeQuestion = pendingOpenCodeQuestions.removeFirst()
    }

    private func sendOpenCodeQuestionReply(
        pendingRequest: PendingOpenCodeQuestionRequest,
        answers: [[String]]
    ) async {
        guard let project = ProjectContext.shared.activeProject,
              project.id == pendingRequest.agentId else { return }

        do {
            try await runtimeRegistry.runtime(for: .openCode).replyToQuestion(
                project: project,
                questionId: pendingRequest.request.id,
                answers: answers
            )
        } catch {
            await MainActor.run {
                addErrorMessage("Failed to answer OpenCode question: \(error.localizedDescription)")
                enqueueOpenCodeQuestion(pendingRequest, announce: false, atFront: true)
            }
        }
    }

    private func sendOpenCodeQuestionReject(
        pendingRequest: PendingOpenCodeQuestionRequest
    ) async {
        guard let project = ProjectContext.shared.activeProject,
              project.id == pendingRequest.agentId else { return }

        do {
            try await runtimeRegistry.runtime(for: .openCode).rejectQuestion(
                project: project,
                questionId: pendingRequest.request.id
            )
        } catch {
            await MainActor.run {
                addErrorMessage("Failed to skip OpenCode question: \(error.localizedDescription)")
                enqueueOpenCodeQuestion(pendingRequest, announce: false, atFront: true)
            }
        }
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

    private func removeTransientOpenCodeMessage(_ message: Message) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }

        messages.remove(at: index)
        if let modelContext {
            modelContext.delete(message)
            saveChanges()
        }
        messagesRevision += 1
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
            if message.role == .assistant, let project = ProjectContext.shared.activeProject {
                prefetchCodeAgentsUIMedia(in: project, messages: [message])
            }
            return message
        }

        let role: MessageRole = isUserMessage ? .user : .assistant
        let message = createMessage(content: content, role: role, isComplete: true, isStreaming: false, proxyEventId: eventId)
        updateMessageWithJSON(message, content: content, originalJSON: jsonData, proxyEventId: eventId)
        ProxyStreamDiagnostics.log("render created id=\(message.id) role=\(role)")
        if message.role == .assistant, let project = ProjectContext.shared.activeProject {
            prefetchCodeAgentsUIMedia(in: project, messages: [message])
        }
        return message
    }

    private func prefetchCodeAgentsUIMedia(in project: RemoteProject, messages: [Message]) {
        let timingStart = DispatchTime.now().uptimeNanoseconds
        var mediaCandidateCount = 0
        var startedTaskCount = 0
        var skippedExistingTaskCount = 0
        defer {
            ChatRecoveryTiming.log(
                runtime: timingRuntimeName(for: project),
                projectID: project.id.uuidString,
                operation: "chat.prefetchCodeAgentsUIMedia",
                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - timingStart,
                metadata: [
                    "inputMessages": .count(messages.count),
                    "mediaCandidates": .count(mediaCandidateCount),
                    "skippedExistingTasks": .count(skippedExistingTaskCount),
                    "startedTasks": .count(startedTaskCount)
                ]
            )
        }

        let maxPrefetchSources = 40
        var seenKeys = Set<String>()
        seenKeys.reserveCapacity(32)
        var sources: [CodeAgentsUIMediaSource] = []
        sources.reserveCapacity(32)

        for message in messages {
            guard message.role == .assistant else { continue }
            guard message.isComplete else { continue }
            let content = message.content
            let lowercased = content.lowercased()
            guard lowercased.contains("codeagents_ui"), lowercased.contains("```") else { continue }

            let segments = CodeAgentsUIBlockExtractor.segments(from: content)
            for segment in segments {
                guard case .ui(let block) = segment else { continue }
                for element in block.elements {
                    switch element {
                    case .image(let image):
                        appendPrefetchSource(image.source)
                    case .gallery(let gallery):
                        for image in gallery.images {
                            appendPrefetchSource(image.source)
                        }
                    case .video(let video):
                        if let poster = video.poster {
                            appendPrefetchSource(poster)
                        }
                    case .card(let card):
                        for nested in card.content {
                            if case .image(let image) = nested {
                                appendPrefetchSource(image.source)
                            }
                            if case .gallery(let gallery) = nested {
                                for image in gallery.images {
                                    appendPrefetchSource(image.source)
                                }
                            }
                            if case .video(let video) = nested, let poster = video.poster {
                                appendPrefetchSource(poster)
                            }
                        }
                    case .markdown, .table, .chart:
                        continue
                    }

                    if sources.count >= maxPrefetchSources {
                        break
                    }
                }

                if sources.count >= maxPrefetchSources {
                    break
                }
            }

            if sources.count >= maxPrefetchSources {
                break
            }
        }

        mediaCandidateCount = sources.count

        for source in sources {
            let key = mediaPrefetchKey(for: source, project: project)
            guard mediaPrefetchTasks[key] == nil else {
                skippedExistingTaskCount += 1
                continue
            }
            let task = Task { [weak self] in
                _ = await ChatMediaLoader.shared.resolveMedia(source, project: project)
                await MainActor.run {
                    self?.mediaPrefetchTasks[key] = nil
                }
            }
            mediaPrefetchTasks[key] = task
            startedTaskCount += 1
        }

        func appendPrefetchSource(_ source: CodeAgentsUIMediaSource) {
            let key = mediaPrefetchKey(for: source, project: project)
            guard !seenKeys.contains(key) else { return }
            seenKeys.insert(key)
            sources.append(source)
        }
    }

    private func mediaPrefetchKey(for source: CodeAgentsUIMediaSource, project: RemoteProject) -> String {
        switch source {
        case .url(let url):
            return "url:\(url.absoluteString)"
        case .projectFile(let path):
            return "project:\(project.id.uuidString):\(path)"
        case .base64(let mediaType, let data):
            return "base64:\(mediaType):\(data.hashValue)"
        }
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
        let timingStart = DispatchTime.now().uptimeNanoseconds
        var timingStatus = ChatRecoveryTiming.Status.complete
        var timingHadActiveSession = false
        var timingHadRecentOutput = false
        defer {
            let project = ProjectContext.shared.activeProject
            ChatRecoveryTiming.log(
                runtime: timingRuntimeName(for: project),
                projectID: project?.id.uuidString,
                operation: "claude.checkForPreviousSession",
                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - timingStart,
                metadata: [
                    "activeSession": .flag(timingHadActiveSession),
                    "localMessages": .count(messages.count),
                    "recentOutput": .flag(timingHadRecentOutput),
                    "status": .status(timingStatus)
                ]
            )
        }
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
            timingStatus = .cancelled
            print("📝 Recovery: Task was cancelled")
            await MainActor.run {
                isLoadingPreviousSession = false
                print("📝 checkForPreviousSession: Set isLoadingPreviousSession = false (task cancelled)")
            }
            return
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

        if claudeService.isProxyChatEnabled {
            await syncProxyHistoryIfNeeded(project: project)
        }

        let sessionCheckStart = DispatchTime.now().uptimeNanoseconds
        let sessionInfo = await claudeService.checkForPreviousSession(
            project: project,
            server: server
        )
        timingHadActiveSession = sessionInfo.hasActiveSession
        timingHadRecentOutput = sessionInfo.recentOutput != nil
        ChatRecoveryTiming.log(
            runtime: timingRuntimeName(for: project),
            projectID: project.id.uuidString,
            operation: "claude.servicePreviousSessionCheck",
            elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - sessionCheckStart,
            metadata: [
                "activeSession": .flag(sessionInfo.hasActiveSession),
                "recentOutput": .flag(sessionInfo.recentOutput != nil),
                "status": .status(.complete)
            ]
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
        let timingStart = DispatchTime.now().uptimeNanoseconds
        var timingStatus = ChatRecoveryTiming.Status.complete
        var primaryEventCount = 0
        var fullResyncEventCount = 0
        var repairEventCount = 0
        var appliedEventCount = 0
        defer {
            ChatRecoveryTiming.log(
                runtime: timingRuntimeName(for: project),
                projectID: project.id.uuidString,
                operation: "proxy.syncHistory",
                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - timingStart,
                metadata: [
                    "appliedEvents": .count(appliedEventCount),
                    "fullResyncEvents": .count(fullResyncEventCount),
                    "localMessages": .count(messages.count),
                    "primaryEvents": .count(primaryEventCount),
                    "repairEvents": .count(repairEventCount),
                    "status": .status(timingStatus)
                ]
            )
        }
        let now = Date()
        if now < proxySyncNextAttemptAt {
            timingStatus = .skipped
            return
        }
        let syncGeneration = proxySyncGeneration
        let previousVersion = project.proxyVersion
        let previousStartedAt = project.proxyStartedAt
        let previousConversationId = project.proxyConversationId
        let usableEventAnchor = ProxyEventRecovery.usableAnchor(project: project, messages: messages)
        let hadMessages = !messages.isEmpty
        let since = usableEventAnchor ?? 0

        // If the per-project anchor was lost but we can derive it from persisted messages,
        // write it back before syncing so we don't fall back to a full replay on re-entry.
        if project.proxyLastEventId != usableEventAnchor,
           let usableEventAnchor,
           ProxyEventRecovery.advanceLastEventId(project: project, to: usableEventAnchor) {
            project.updateLastModified()
            saveChanges()
        }

        let conversationSuffix = project.proxyConversationId.map { String($0.suffix(6)) } ?? "nil"
        ProxyStreamDiagnostics.log(
            "sync start conv=...\(conversationSuffix) messages=\(messages.count) storedLast=\(String(describing: project.proxyLastEventId)) usableAnchor=\(String(describing: usableEventAnchor)) since=\(since)"
        )
        do {
            let primaryFetchStart = DispatchTime.now().uptimeNanoseconds
            let (events, info) = try await claudeService.fetchProxyEvents(project: project, since: since)
            primaryEventCount = events.count
            ChatRecoveryTiming.log(
                runtime: timingRuntimeName(for: project),
                projectID: project.id.uuidString,
                operation: "proxy.fetchEvents.primary",
                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - primaryFetchStart,
                metadata: [
                    "events": .count(events.count),
                    "sinceEventId": .count(since),
                    "status": .status(.complete)
                ]
            )
            guard syncGeneration == proxySyncGeneration else { return }
            proxySyncRetryCount = 0
            proxySyncNextAttemptAt = .distantPast
            showSyncRetryIndicator = false

            if applyUnreadCursorUpdate(from: info, project: project) {
                project.updateLastModified()
                saveChanges()
            }

            let initialBind = previousConversationId == nil && usableEventAnchor != nil
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
            let shouldFullResync = ProxyEventRecovery.shouldDestructivelyResync(
                previousConversationId: previousConversationId,
                currentConversationId: project.proxyConversationId,
                didInitiallyBindFromMissingConversation: initialBind
            )

            // Only do a repair replay when we have messages but no event id anchor. This should be rare and
            // indicates corrupted local state.
            let shouldRepair = ProxyEventRecovery.shouldRepairFullReplay(
                hasLocalMessages: hadMessages,
                usableAnchor: usableEventAnchor
            )

            if shouldFullResync && since != 0 {
                let fullResyncStart = DispatchTime.now().uptimeNanoseconds
                let (fullEvents, _) = try await claudeService.fetchProxyEvents(project: project, since: 0)
                fullResyncEventCount = fullEvents.count
                ChatRecoveryTiming.log(
                    runtime: timingRuntimeName(for: project),
                    projectID: project.id.uuidString,
                    operation: "proxy.fetchEvents.fullResync",
                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - fullResyncStart,
                    metadata: ["events": .count(fullEvents.count), "status": .status(.complete)]
                )
                eventsToApply = fullEvents
            }

            if shouldRepair && since != 0 {
                // Non-destructive repair: replay the full conversation and upsert/dedupe locally.
                let repairStart = DispatchTime.now().uptimeNanoseconds
                let (fullEvents, _) = try await claudeService.fetchProxyEvents(project: project, since: 0)
                repairEventCount = fullEvents.count
                ChatRecoveryTiming.log(
                    runtime: timingRuntimeName(for: project),
                    projectID: project.id.uuidString,
                    operation: "proxy.fetchEvents.repair",
                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - repairStart,
                    metadata: ["events": .count(fullEvents.count), "status": .status(.complete)]
                )
                eventsToApply = fullEvents
            }

            if shouldFullResync {
                resetMessagesForProxySync(project: project)
            }

            guard syncGeneration == proxySyncGeneration else { return }
            guard !eventsToApply.isEmpty else { return }

            let didAdvanceLastEventId = ProxyEventRecovery.advanceLastEventId(project: project, events: eventsToApply)
            if didAdvanceLastEventId {
                project.updateLastModified()
            }

            let messageId = project.activeStreamingMessageId ?? UUID()
            appliedEventCount = eventsToApply.count
            await applyProxyEvents(eventsToApply, project: project, messageId: messageId)
        } catch {
            timingStatus = .failed
            if let proxyError = error as? ProxyStreamError,
               proxyError.isConversationRecoveryError {
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
        activeOpenCodeQuestion = nil
        pendingOpenCodeQuestions = []
        handledOpenCodeQuestionIds = []

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
        let timingStart = DispatchTime.now().uptimeNanoseconds
        var skippedDuplicateEventIds = 0
        var skippedDuplicateLines = 0
        var insertedMessages = 0
        var updatedMessages = 0
        var resultEvents = 0
        defer {
            ChatRecoveryTiming.log(
                runtime: timingRuntimeName(for: project),
                projectID: project.id.uuidString,
                operation: "proxy.applyEvents",
                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - timingStart,
                metadata: [
                    "events": .count(events.count),
                    "finalLocalMessages": .count(messages.count),
                    "insertedMessages": .count(insertedMessages),
                    "resultEvents": .count(resultEvents),
                    "skippedDuplicateEventIds": .count(skippedDuplicateEventIds),
                    "skippedDuplicateLines": .count(skippedDuplicateLines),
                    "updatedMessages": .count(updatedMessages)
                ]
            )
        }
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
            if ProxyEventRecovery.isDuplicateReplayEvent(event, existingEventIds: seenEventIds) {
                skippedDuplicateEventIds += 1
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
                skippedDuplicateLines += 1
                if let metadata = enrichedChunk.metadata {
                    let didApply = applyProxyEventIdToExistingMessageIfPossible(
                        jsonLine: jsonLine,
                        metadata: metadata,
                        proxyEventId: event.eventId
                    )
                    if didApply, let eventId = event.eventId {
                        seenEventIds.insert(eventId)
                        updatedMessages += 1
                    }
                }
                continue
            }

            if let eventId = event.eventId {
                seenEventIds.insert(eventId)
            }
            seenLines.insert(jsonLine)

            let messageCountBeforeUpsert = messages.count
            if let message = upsertStreamMessage(from: enrichedChunk, reuseMessage: placeholderMessage) {
                if messages.count > messageCountBeforeUpsert {
                    insertedMessages += 1
                } else {
                    updatedMessages += 1
                }
                placeholderMessage = nil
                lastMessage = message
                if message.role == .assistant {
                    lastAssistantMessage = message
                }
            }

            if let type = enrichedChunk.metadata?["type"] as? String, type == "result" {
                resultEvents += 1
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
        let timingStart = DispatchTime.now().uptimeNanoseconds
        var timingStatus = ChatRecoveryTiming.Status.complete
        var chunkCount = 0
        var duplicateSkips = 0
        var insertedMessages = 0
        var updatedMessages = 0
        var resultEvents = 0
        var errorChunks = 0
        defer {
            ChatRecoveryTiming.log(
                runtime: timingRuntimeName(for: project),
                projectID: project.id.uuidString,
                operation: "proxy.resumeActiveSession",
                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - timingStart,
                metadata: [
                    "chunks": .count(chunkCount),
                    "duplicateSkips": .count(duplicateSkips),
                    "errorChunks": .count(errorChunks),
                    "insertedMessages": .count(insertedMessages),
                    "resultEvents": .count(resultEvents),
                    "status": .status(timingStatus),
                    "updatedMessages": .count(updatedMessages)
                ]
            )
        }
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
                timingStatus = .failed
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
                chunkCount += 1
                saveChangesThrottled()

                if chunk.isError {
                    errorChunks += 1
                    timingStatus = .failed
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
                    duplicateSkips += 1
                    if let metadata = chunk.metadata {
                        let didApply = applyProxyEventIdToExistingMessageIfPossible(
                            jsonLine: jsonLine,
                            metadata: metadata,
                            proxyEventId: proxyEventId(from: metadata)
                        )
                        if didApply {
                            updatedMessages += 1
                        }
                    }
                    continue
                }
                seenLines.insert(jsonLine)

                let messageCountBeforeUpsert = messages.count
                if let message = upsertStreamMessage(from: chunk, reuseMessage: placeholderMessage) {
                    if messages.count > messageCountBeforeUpsert {
                        insertedMessages += 1
                    } else {
                        updatedMessages += 1
                    }
                    placeholderMessage = nil
                    streamingMessage = nil
                    streamingBlocks = []
                    project.activeStreamingMessageId = message.id
                    project.updateLastModified()
                }

                if let type = chunk.metadata?["type"] as? String, type == "result" {
                    resultEvents += 1
                    project.activeStreamingMessageId = nil
                    project.updateLastModified()
                    isProcessing = false
                    saveChanges()
                    break
                }
            }
        } catch {
            timingStatus = .failed
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
