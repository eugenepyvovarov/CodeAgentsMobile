//
//  ChatViewModel.swift
//  CodeAgentsMobile
//
//  Purpose: Chat state orchestrator (OpenCode-only). Extensions hold send/hydrate/MCP/tools.
//

import SwiftUI
import Observation
import SwiftData
import UIKit

/// ViewModel for the chat interface.
/// Handles message display, streaming, and persistence (OpenCode-only).
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

    /// Keeps the process alive long enough for an in-flight OpenCode reply to finish
    /// after the user backgrounds the app, so we can still fire the completion push.
    var openCodeSendBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    
    /// Model context for persistence
    var modelContext: ModelContext?
    
    /// Current project ID
    var projectId: UUID?
    
    /// Runtime-aware MCP service reference
    let mcpService = CodingAgentMCPService.shared

    let runtimeSelectionStore: CodingAgentRuntimeSelectionStore
    let runtimeRegistry: CodingAgentRuntimeRegistry

    var mediaPrefetchTasks: [String: MediaPrefetchTaskState] = [:]
    var deferredStartupTask: Task<Void, Never>?
    var deferredStartupProjectID: UUID?
    var deferredStartupToken: UUID?

    /// Loading state for previous session / hydration
    var isLoadingPreviousSession = false

    /// Active session indicator - shows when resuming a previous session
    var showActiveSessionIndicator = false

    /// Reserved for transient recovery retry UI (OpenCode hydrate soft-failures).
    var showSyncRetryIndicator = false

    /// Legacy Claude provider mismatch (always nil on OpenCode-only chat; kept for ChatDetailView API).
    var providerMismatch: ClaudeProviderMismatch?

    /// Track if we've already run OpenCode open recovery for this project configuration.
    var hasCheckedForPreviousSession = false

    /// Track the active session check / open recovery task
    var sessionCheckTask: Task<Void, Never>?

    /// Cancellable full-session OpenCode hydration that runs after bounded visible-path recovery.
    var openCodeFullHydrationTask: Task<Void, Never>?

    /// In-flight OpenCode `/event` consumer for the active send. Soft-steer reuses this instead of dual-attaching.
    var openCodeSendTask: Task<Void, Never>?

    /// Generation token for the active send stream. Invalidated on project switch / clear / stop.
    var openCodeSendGeneration: UUID = UUID()

    /// Generation token for hydration work. Invalidated on project switch / clear / session replace.
    var openCodeHydrationGeneration: UUID = UUID()

    /// Track if configuration is in progress to prevent race conditions
    var isConfiguring = false
    
    /// Cached MCP servers for the current project
    var cachedMCPServers: [MCPServer] = []
    var mcpCacheLastFetchedAt: Date?
    var isMCPCacheInvalidated = true
    let mcpCacheStaleInterval: TimeInterval = 300
    
    /// Track if MCP servers are being fetched
    var isFetchingMCPServers = false

    /// Stale streaming timeout used when recovery finds no active session
    let staleStreamingTimeout: TimeInterval = 300

    /// Active tool permission request awaiting user input
    var activeToolApproval: ToolApprovalRequest?

    /// Queue for additional tool permission requests
    var pendingToolApprovals: [ToolApprovalRequest] = []

    /// Track handled tool permission IDs to avoid duplicate prompts
    var handledToolPermissionIds: Set<String> = []

    /// Active OpenCode question request awaiting user input
    var activeOpenCodeQuestion: PendingOpenCodeQuestionRequest?

    /// Queue for additional OpenCode question requests
    var pendingOpenCodeQuestions: [PendingOpenCodeQuestionRequest] = []

    /// Track handled OpenCode question IDs to avoid duplicate prompts
    var handledOpenCodeQuestionIds: Set<String> = []

    let toolApprovalStore = ToolApprovalStore.shared

    var pendingSaveTask: Task<Void, Never>?
    var lastSaveTime: Date = .distantPast
    let saveThrottleInterval: TimeInterval = 0.5

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
        // Invalidate in-flight send/hydrate ownership when reconfiguring.
        openCodeSendTask?.cancel()
        openCodeSendTask = nil
        openCodeSendGeneration = UUID()
        openCodeHydrationGeneration = UUID()

        // Reset the flag when project changes
        if self.projectId != projectId {
            cancelDeferredStartup(reason: "projectSwitch", projectID: self.projectId)
            hasCheckedForPreviousSession = false
            // Also reset loading states when switching projects
            isLoadingPreviousSession = false
            showActiveSessionIndicator = false
            isProcessing = false
            streamingMessage = nil
            streamingBlocks = []
            // Clear cached MCP servers when switching projects
            cachedMCPServers = []
            mcpCacheLastFetchedAt = nil
            isMCPCacheInvalidated = true
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
        // Local-first: render persisted messages before remote recovery / migration side effects.
        loadMessages()
        let configuredProject = ProjectContext.shared.activeProject
        // Chat is OpenCode-only after Claude→OpenCode migration.
        providerMismatch = nil

        toolApprovalStore.ensureDefaults(for: projectId)
        
        // Check for previous session after configuration (only if not already checked)
        if !hasCheckedForPreviousSession {
            // Cancel any existing check
            sessionCheckTask?.cancel()

            // Migrate legacy Claude projects, then recover via OpenCode only.
            sessionCheckTask = Task {
                let project = ProjectContext.shared.activeProject ?? configuredProject
                if let project {
                    let migrationReport = await ClaudeToOpenCodeMigrationService.shared.migrateIfNeeded(
                        project: project,
                        modelContext: modelContext
                    )
                    if migrationReport.didMigrate || migrationReport.mcp.didImport {
                        invalidateMCPCache()
                        saveChanges()
                    }
                }

                let activeProject = ProjectContext.shared.activeProject ?? configuredProject
                providerMismatch = nil
                let runtimeKind = CodingAgentRuntimeKind.openCode

                if let project = activeProject {
                    let openDecision = OpenCodeChatOpenPolicy.decision(
                        hasOpenCodeSession: project.openCodeSessionId?
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                        localMessageCount: self.messages.count,
                        activeStreamingMessageId: project.activeStreamingMessageId,
                        messages: self.messages
                    )
                    ChatRecoveryTiming.log(
                        runtime: CodingAgentRuntimeKind.openCode.rawValue,
                        projectID: project.id.uuidString,
                        operation: "opencode.chatOpen.decision",
                        elapsedNanoseconds: 0,
                        metadata: [
                            "localMessages": .count(self.messages.count),
                            "blocksOpen": .flag(OpenCodeChatOpenPolicy.blocksChatOpen(for: openDecision)),
                            "status": .status(.complete)
                        ]
                    )
                    if OpenCodeChatOpenPolicy.blocksChatOpen(for: openDecision) {
                        await hydrateOpenCodeMessagesIfNeeded(project: project)
                    } else {
                        // Recent idle reopen: show SwiftData immediately; hydrate after UI is ready.
                        scheduleOpenCodeBackgroundHydration(project: project)
                    }
                }
                hasCheckedForPreviousSession = true
                scheduleDeferredStartupAfterChatReady(projectID: projectId, runtimeKind: runtimeKind)
            }
        } else {
            scheduleDeferredStartupAfterChatReady(projectID: projectId, runtimeKind: .openCode)
        }
    }


    /// Compatibility no-op: Claude proxy polling is retired (OpenCode uses SSE + hydration).
    func startProxyPolling() {
        stopProxyPolling()
    }

    func stopProxyPolling() {
        // No proxy poller remains.
    }


    /// Refresh chat from OpenCode (name kept for push / menu call sites).
    func refreshProxyEvents(conversationId: String? = nil) async {
        guard let project = ProjectContext.shared.activeProject,
              projectId == project.id,
              modelContext != nil else { return }
        if project.applyOpenCodeSessionFromPush(conversationId) {
            saveChanges()
        }
        await hydrateOpenCodeMessagesIfNeeded(project: project)
    }

    func refreshProviderMismatch(for project: RemoteProject?) {
        // Chat is OpenCode-only; Claude provider mismatch banners no longer apply.
        _ = project
        providerMismatch = nil
    }

    func reloadMessages() {
        loadMessages()
        providerMismatch = nil
    }

    
    /// Clear all messages and start fresh
    func clearChat() {
        // Cancel ownership of any in-flight send / hydration so they cannot repopulate state.
        openCodeSendTask?.cancel()
        openCodeSendTask = nil
        openCodeSendGeneration = UUID()
        openCodeFullHydrationTask?.cancel()
        openCodeFullHydrationTask = nil
        openCodeHydrationGeneration = UUID()
        sessionCheckTask?.cancel()
        sessionCheckTask = nil
        isProcessing = false
        streamingMessage = nil
        streamingBlocks = []

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
        if let project = ProjectContext.shared.activeProject {
            project.lastSuccessfulClaudeProviderRawValue = nil
        }
        providerMismatch = nil
        hasCheckedForPreviousSession = false
        isLoadingPreviousSession = false
        print("📝 clearChat: Set isLoadingPreviousSession = false")
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        lastSaveTime = .distantPast
        messagesRevision += 1
        streamingRedrawToken = UUID()
        stopProxyPolling()
        showSyncRetryIndicator = false
        activeToolApproval = nil
        pendingToolApprovals = []
        handledToolPermissionIds = []
        activeOpenCodeQuestion = nil
        pendingOpenCodeQuestions = []
        handledOpenCodeQuestionIds = []

        // Clear active streaming message ID when clearing chat
        if let project = ProjectContext.shared.activeProject {
            project.activeStreamingMessageId = nil
            project.clearClaudeProxyTransportState(clearActiveStreamingMessage: true)
            project.resetOpenCodeRuntimeState()
            Task { @MainActor in
                do {
                    try await ProxyTaskService.shared.clearActiveOpenCodeSession(project: project)
                } catch {
                    SSHLogger.log("Failed to clear active OpenCode task session for project \(project.id): \(error)", level: .warning)
                }
            }
        }

        saveChanges()
    }

    /// True when the current chat still owns work for the given project + generation.
    func ownsOpenCodeWork(projectID: UUID, generation: UUID, kind: OpenCodeWorkOwnershipKind) -> Bool {
        guard projectId == projectID else { return false }
        switch kind {
        case .send:
            return openCodeSendGeneration == generation
        case .hydration:
            return openCodeHydrationGeneration == generation
        }
    }
}

enum OpenCodeWorkOwnershipKind {
    case send
    case hydration
}

// Re-open ChatViewModel for remaining methods that were below clearChat.
extension ChatViewModel {
    // MARK: - Unread

    func markUnreadAsRead(for project: RemoteProject) {
        // OpenCode unread is keyed by session id; prefer it over legacy proxy conversation ids
        // so soft-sync / interactive reply do not treat every poll as a session change.
        if project.unreadConversationId == nil {
            if let sessionId = project.openCodeSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sessionId.isEmpty {
                project.unreadConversationId = sessionId
            } else if let conversationId = project.proxyConversationId?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                      !conversationId.isEmpty {
                project.unreadConversationId = conversationId
            }
        }

        let target = project.lastKnownUnreadCursor
        guard target > project.lastReadUnreadCursor else { return }
        project.lastReadUnreadCursor = target
        saveChanges()
        if let modelContext {
            UnreadBadgeService.refreshAppIconBadge(using: modelContext)
        }
    }

    
    /// Clear all loading states - useful when view disappears
    func clearLoadingStates() {
        sessionCheckTask?.cancel()
        sessionCheckTask = nil
        cancelDeferredStartup(reason: "clearLoadingStates", projectID: projectId)
        // Flush any pending throttled saves so recovery anchors persist across view re-entries.
        saveChanges()
        stopProxyPolling()

        isLoadingPreviousSession = false
        showActiveSessionIndicator = false
        showSyncRetryIndicator = false
        activeToolApproval = nil
        pendingToolApprovals = []
        handledToolPermissionIds = []
        activeOpenCodeQuestion = nil
        pendingOpenCodeQuestions = []
        handledOpenCodeQuestionIds = []
        print("📝 clearLoadingStates: Cleared all loading states and cancelled pending tasks")
    }


    /// Clean up resources before view disappears.
    ///
    /// Intentionally keeps an in-flight OpenCode send task alive so a reply that finishes
    /// after the user leaves chat still updates SwiftData, unread badges, and push.
    /// Explicit Stop / project switch still cancels via `abortCurrentResponse` / new send.
    func cleanup() {
        sessionCheckTask?.cancel()
        sessionCheckTask = nil
        openCodeFullHydrationTask?.cancel()
        openCodeFullHydrationTask = nil
        // Do not cancel `openCodeSendTask` or rotate `openCodeSendGeneration` here.
        // Do not end the OpenCode send background task — stream may still be finishing.
        openCodeHydrationGeneration = UUID()
        cancelDeferredStartup(reason: "cleanup", projectID: projectId)
        saveChanges()
        stopProxyPolling()

        streamingMessage = nil
        streamingBlocks = []
        isLoadingPreviousSession = false
        showActiveSessionIndicator = false
        showSyncRetryIndicator = false
        activeToolApproval = nil
        pendingToolApprovals = []
        handledToolPermissionIds = []
        activeOpenCodeQuestion = nil
        pendingOpenCodeQuestions = []
        handledOpenCodeQuestionIds = []

        print("📝 cleanup: Cleaned up view resources (send stream may continue in background)")
    }

    /// Request extra runtime so an OpenCode reply can finish after the user leaves the app.
    func beginOpenCodeSendBackgroundExecution() {
        endOpenCodeSendBackgroundExecution()
        var taskId = UIBackgroundTaskIdentifier.invalid
        taskId = UIApplication.shared.beginBackgroundTask(withName: "opencode-send-stream") {
            // Expiration handler: end immediately (required by UIKit).
            UIApplication.shared.endBackgroundTask(taskId)
            Task { @MainActor [weak self] in
                if self?.openCodeSendBackgroundTaskID == taskId {
                    self?.openCodeSendBackgroundTaskID = .invalid
                }
            }
        }
        openCodeSendBackgroundTaskID = taskId
    }

    func endOpenCodeSendBackgroundExecution() {
        let taskId = openCodeSendBackgroundTaskID
        guard taskId != .invalid else { return }
        openCodeSendBackgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(taskId)
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

    func activeRuntimeKind(for project: RemoteProject) -> CodingAgentRuntimeKind {
        CodingAgentRuntimeResolver.runtimeKind(for: project, selectionStore: runtimeSelectionStore)
    }

    func timingRuntimeName(for project: RemoteProject?) -> String {
        guard let project else { return CodingAgentRuntimeKind.openCode.rawValue }
        return activeRuntimeKind(for: project).rawValue
    }
}
