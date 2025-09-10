//
//  ClaudeCodeService.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-01.
//
//  Purpose: Manages Claude Code CLI interactions
//  - Handles session management
//  - Manages authentication
//  - Processes streaming responses
//  - Maintains conversation context
//

import Foundation
import SwiftUI
import SwiftData

/// Buffers partial lines and yields complete lines
class LineBuffer {
    private var buffer = ""
    
    func addData(_ data: String) -> [String] {
        buffer += data
        var lines: [String] = []
        
        while let newlineIndex = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            if !line.isEmpty {
                lines.append(line)
            }
        }
        
        return lines
    }
    
    func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        let remaining = buffer
        buffer = ""
        return remaining
    }
}

/// Authentication method for Claude Code
enum ClaudeAuthMethod: String, CaseIterable {
    case apiKey = "apiKey"
    case token = "token"
}

/// Authentication status for Claude Code
enum ClaudeAuthStatus {
    case authenticated
    case missingCredentials
    case invalidCredentials
    case notChecked
}


/// Message chunk for streaming responses
struct MessageChunk {
    let content: String
    let isComplete: Bool
    let isError: Bool
    let metadata: [String: Any]?
}

/// Response format from Claude Code JSON output
struct ClaudeResponse: Decodable {
    let type: String
    let subtype: String?
    let isError: Bool?
    let result: String?
    let sessionId: String?
    let totalCostUsd: Double?
    let message: ClaudeMessage?
    let cwd: String?
    let tools: [String]?
    let durationMs: Int?
    let usage: [String: Any]?
    
    enum CodingKeys: String, CodingKey {
        case type, subtype, result, message, cwd, tools, usage
        case isError = "is_error"
        case sessionId = "session_id"
        case totalCostUsd = "total_cost_usd"
        case durationMs = "duration_ms"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        subtype = try container.decodeIfPresent(String.self, forKey: .subtype)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError)
        result = try container.decodeIfPresent(String.self, forKey: .result)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        totalCostUsd = try container.decodeIfPresent(Double.self, forKey: .totalCostUsd)
        message = try container.decodeIfPresent(ClaudeMessage.self, forKey: .message)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        tools = try container.decodeIfPresent([String].self, forKey: .tools)
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        // Skip decoding usage as it's complex
        usage = nil
    }
}

/// Single streaming response (not in array)
struct ClaudeStreamingResponse: Decodable {
    let type: String
    let subtype: String?
    let isError: Bool?
    let result: String?
    let sessionId: String?
    let totalCostUsd: Double?
    let message: ClaudeMessage?
    let cwd: String?
    let tools: [String]?
    let durationMs: Int?
    let usage: [String: Any]?
    
    enum CodingKeys: String, CodingKey {
        case type, subtype, result, message, cwd, tools, usage
        case isError = "is_error"
        case sessionId = "session_id"
        case totalCostUsd = "total_cost_usd"
        case durationMs = "duration_ms"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        subtype = try container.decodeIfPresent(String.self, forKey: .subtype)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError)
        result = try container.decodeIfPresent(String.self, forKey: .result)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        totalCostUsd = try container.decodeIfPresent(Double.self, forKey: .totalCostUsd)
        message = try container.decodeIfPresent(ClaudeMessage.self, forKey: .message)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        tools = try container.decodeIfPresent([String].self, forKey: .tools)
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        // Skip decoding usage as it's complex
        usage = nil
    }
}

/// Message structure in verbose output
struct ClaudeMessage: Decodable {
    let id: String?
    let type: String?
    let role: String?
    let model: String?
    let content: [ClaudeContent]?
    let stopReason: String?
    let usage: [String: Any]?
    
    enum CodingKeys: String, CodingKey {
        case id, type, role, model, content
        case stopReason = "stop_reason"
        case usage
    }
    
    // Custom decoding to handle the content array
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        content = try container.decodeIfPresent([ClaudeContent].self, forKey: .content)
        stopReason = try container.decodeIfPresent(String.self, forKey: .stopReason)
        // Skip decoding usage as it's complex
        usage = nil
    }
    
    // Helper to extract text content
    var textContent: String? {
        guard let content = content else { return nil }
        let texts = content.compactMap { item in
            if case .text(let text) = item {
                return text
            }
            return nil
        }
        return texts.isEmpty ? nil : texts.joined(separator: " ")
    }
}

/// Content item in Claude message
enum ClaudeContent: Decodable {
    case text(String)
    case toolUse(ToolUse)
    case toolResult(ToolResult)
    case unknown
    
    struct ToolUse: Decodable {
        let id: String
        let name: String
        let input: [String: Any]?
        
        enum CodingKeys: String, CodingKey {
            case id, name, input
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            // Skip complex input decoding
            input = nil
        }
    }
    
    struct ToolResult: Decodable {
        let toolUseId: String
        let content: String?
        
        enum CodingKeys: String, CodingKey {
            case toolUseId = "tool_use_id"
            case content
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case type, text, id, name, input
        case toolUseId = "tool_use_id"
        case content
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        
        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "tool_use":
            let toolUse = try ToolUse(from: decoder)
            self = .toolUse(toolUse)
        case "tool_result":
            let toolResult = try ToolResult(from: decoder)
            self = .toolResult(toolResult)
        default:
            self = .unknown
        }
    }
}

/// Connection state for recovery
enum ConnectionState {
    case idle
    case connecting
    case active
    case backgroundSuspended(since: Date)
    case recovering(attempt: Int)
    case failed(Error)
    
    var canRecover: Bool {
        switch self {
        case .backgroundSuspended, .recovering:
            return true
        case .failed(let error):
            // Check error patterns directly here
            let errorString = error.localizedDescription.lowercased()
            let recoverablePatterns = [
                "connection", "network", "timeout", "broken pipe",
                "socket", "disconnected", "lost", "reset", "abort",
                "ebadf", "bad file descriptor", "closed channel", "already closed"
            ]
            return recoverablePatterns.contains { errorString.contains($0) }
        default:
            return false
        }
    }
    
    var description: String {
        switch self {
        case .idle:
            return "idle"
        case .connecting:
            return "connecting"
        case .active:
            return "active"
        case .backgroundSuspended(let date):
            return "suspended since \(date)"
        case .recovering(let attempt):
            return "recovering (attempt \(attempt))"
        case .failed(let error):
            return "failed: \(error.localizedDescription)"
        }
    }
}

/// Service for managing Claude Code interactions
@MainActor
class ClaudeCodeService: ObservableObject {
    // MARK: - Singleton
    
    static let shared = ClaudeCodeService()
    
    // MARK: - Properties
    
    
    /// Current authentication status
    @Published var authStatus: ClaudeAuthStatus = .notChecked
    
    /// Claude installation status per server
    @Published var claudeInstallationStatus: [UUID: Bool] = [:]
    
    /// SSH service reference
    private let sshService = ServiceManager.shared.sshService
    
    /// Project context reference
    private let projectContext = ProjectContext.shared
    
    /// UserDefaults key for auth method preference
    private let claudeAuthMethodKey = "claudeAuthMethod"
    
    /// Track last read positions for output files
    private var lastReadPositions: [UUID: Int] = [:]
    
    /// Track connection states per project
    private var connectionStates: [UUID: ConnectionState] = [:]
    
    /// Track active stream continuations for recovery
    private var activeStreamContinuations: [UUID: AsyncThrowingStream<MessageChunk, Error>.Continuation] = [:]
    
    /// Track the periodic cleanup task
    private var cleanupTask: Task<Void, Never>?
    
    
    // MARK: - Initialization
    
    private init() {
        // Set up app lifecycle notifications
        setupLifecycleObservers()
        
        // Start periodic cleanup task
        startPeriodicCleanup()
    }
    
    deinit {
        // Cancel cleanup task
        cleanupTask?.cancel()
        
        // Clean up all active continuations
        for (projectId, continuation) in activeStreamContinuations {
            print("⚠️ Cleaning up abandoned continuation for project: \(projectId)")
            continuation.finish()
        }
        activeStreamContinuations.removeAll()
        
        // Remove all notification observers
        NotificationCenter.default.removeObserver(self)
    }
    
    /// Set up observers for app lifecycle events
    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    @objc private func appWillResignActive() {
        // Mark all active connections as background suspended
        for (projectId, state) in connectionStates {
            if case .active = state {
                transitionConnectionState(for: projectId, to: .backgroundSuspended(since: Date()))
            }
        }
    }
    
    @objc private func appDidBecomeActive() {
        // Attempt to recover SSH connections when app becomes active
        Task {
            await recoverSSHConnectionsOnForeground()
        }
    }
    
    /// Recover SSH connections when app returns to foreground
    private func recoverSSHConnectionsOnForeground() async {
        print("🔄 Recovering SSH connections on app foreground")
        
        // First, clean up any stale connections
        let cleanedCount = await sshService.cleanupStaleConnections()
        if cleanedCount > 0 {
            print("🧹 Cleaned up \(cleanedCount) stale SSH connections")
        }
        
        // Then attempt to reconnect background-suspended connections
        let reconnectedCount = await sshService.reconnectBackgroundConnections()
        if reconnectedCount > 0 {
            print("🔗 Reconnected \(reconnectedCount) SSH connections")
            
            // Notify that connections have been recovered
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .sshConnectionsRecovered,
                    object: nil,
                    userInfo: ["reconnectedCount": reconnectedCount]
                )
            }
        }
        
        // Also trigger connection state transitions
        for (projectId, state) in connectionStates {
            if case .backgroundSuspended = state {
                transitionConnectionState(for: projectId, to: .recovering(attempt: 1))
            }
        }
    }
    
    /// Start periodic cleanup of orphaned files
    private func startPeriodicCleanup() {
        cleanupTask = Task {
            // Run cleanup every hour
            while !Task.isCancelled {
                await cleanupOrphanedFiles()
                
                // Sleep for 1 hour
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
        }
    }
    
    /// Clean up orphaned nohup files older than 24 hours
    private func cleanupOrphanedFiles() async {
        // Find and remove files older than 24 hours
        let cleanupCommand = """
            find /tmp -type f \\( -name '*_claude.out' -o -name '*_claude.pid' \\) -mmin +1440 -delete 2>/dev/null || true
        """
        
        // Run cleanup on the active server if available
        if let server = projectContext.activeServer,
           let project = projectContext.activeProject {
            do {
                if let session = try? await sshService.getConnection(for: project, purpose: .claude) {
                    let result = try await session.execute(cleanupCommand)
                    print("🧹 Periodic cleanup on \(server.name): \(result.isEmpty ? "No orphaned files found" : result)")
                }
            } catch {
                print("⚠️ Periodic cleanup failed: \(error)")
            }
        }
    }
    
    // MARK: - Public Methods
    
    /// Get the current authentication method
    func getCurrentAuthMethod() -> ClaudeAuthMethod {
        let rawValue = UserDefaults.standard.string(forKey: claudeAuthMethodKey) ?? ClaudeAuthMethod.apiKey.rawValue
        return ClaudeAuthMethod(rawValue: rawValue) ?? .apiKey
    }
    
    /// Check if Claude is installed on the given server
    func checkClaudeInstallation(for server: Server) async -> Bool {
        do {
            let sshSession = try await sshService.connect(to: server)
            let result = try await withTimeout(seconds: 10) {
                // execute() now loads shell profiles by default
                try await sshSession.execute("which claude")
            }
            // Check if the result contains a valid path (not "not found" or empty)
            let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
            let isInstalled = !trimmedResult.isEmpty && 
                              !trimmedResult.contains("not found") && 
                              !trimmedResult.contains("command not found") &&
                              trimmedResult.hasPrefix("/") // Valid paths start with /
            
            claudeInstallationStatus[server.id] = isInstalled
            print("🔍 Claude installation check result: '\(trimmedResult)' -> installed: \(isInstalled)")
            return isInstalled
        } catch {
            print("❌ Claude installation check error: \(error)")
            // Don't update cache on error
            return claudeInstallationStatus[server.id] ?? false
        }
    }
    
    /// Set the authentication method
    func setAuthMethod(_ method: ClaudeAuthMethod) {
        UserDefaults.standard.set(method.rawValue, forKey: claudeAuthMethodKey)
        
        // Reset auth status when method changes
        authStatus = .notChecked
    }
    
    /// Build authentication export command based on current method
    private func buildAuthExportCommand() throws -> String {
        let authMethod = getCurrentAuthMethod()
        
        switch authMethod {
        case .apiKey:
            guard KeychainManager.shared.hasAPIKey() else {
                authStatus = .missingCredentials
                throw ClaudeError.authenticationRequired
            }
            let apiKey = try KeychainManager.shared.retrieveAPIKey()
            return "export ANTHROPIC_API_KEY=\"\(apiKey)\" && "
            
        case .token:
            guard KeychainManager.shared.hasAuthToken() else {
                authStatus = .missingCredentials
                throw ClaudeError.authenticationRequired
            }
            let token = try KeychainManager.shared.retrieveAuthToken()
            return "export CLAUDE_CODE_OAUTH_TOKEN=\"\(token)\" && "
        }
    }
    
    /// Check if credentials are configured for the current auth method
    func hasCredentials() -> Bool {
        let authMethod = getCurrentAuthMethod()
        
        switch authMethod {
        case .apiKey:
            return KeychainManager.shared.hasAPIKey()
        case .token:
            return KeychainManager.shared.hasAuthToken()
        }
    }
    
    /// Clear credentials when switching auth methods
    func clearOtherCredentials(keepingMethod method: ClaudeAuthMethod) {
        switch method {
        case .apiKey:
            // Keep API key, delete token
            try? KeychainManager.shared.deleteAuthToken()
        case .token:
            // Keep token, delete API key
            try? KeychainManager.shared.deleteAPIKey()
        }
    }
    
    
    
    /// Send a message to Claude Code and stream the response
    func sendMessage(
        _ text: String,
        in project: RemoteProject,
        sessionId: String? = nil,
        messageId: UUID? = nil,
        mcpServers: [MCPServer] = []
    ) -> AsyncThrowingStream<MessageChunk, Error> {
        AsyncThrowingStream { continuation in
            // Store continuation for recovery
            activeStreamContinuations[project.id] = continuation
            transitionConnectionState(for: project.id, to: .connecting)
            
            Task {
                do {
                    guard let server = projectContext.activeServer else {
                        throw ClaudeError.noActiveServer
                    }
                    
                    // Get SSH session for this project and purpose
                    let sshSession = try await sshService.getConnection(for: project, purpose: .claude)
                    
                    // Generate output file paths using message ID if provided
                    let fileIdentifier = messageId?.uuidString ?? "\(server.id.uuidString.prefix(8))_\(project.id.uuidString.prefix(8))"
                    let outputFile = "/tmp/\(fileIdentifier)_claude.out"
                    let pidFile = "/tmp/\(fileIdentifier)_claude.pid"
                    
                    // Kill any existing process and clean up
                    let cleanupCommand = """
                        if [ -f \(pidFile) ]; then
                            kill $(cat \(pidFile)) 2>/dev/null || true
                            rm -f \(pidFile)
                        fi
                        > \(outputFile)
                    """
                    _ = try await sshSession.execute(cleanupCommand)
                    
                    // Prepare the message
                    let escapedMessage = text
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                        .replacingOccurrences(of: "\n", with: "\\n")
                    
                    // Build the Claude command
                    var claudeCommand = "cd \"\(project.path)\" && "
                    claudeCommand += try buildAuthExportCommand()
                    claudeCommand += "claude --print \"\(escapedMessage)\" "
                    claudeCommand += "--output-format stream-json --verbose "
                    
                    // Build allowed tools list including MCP servers
                    var allowedTools = ["Bash", "Write", "Edit", "MultiEdit", "NotebookEdit", "Read", "LS", "Grep", "Glob", "WebFetch"]
                    
                    // Add MCP tools with mcp__ prefix
                    for server in mcpServers {
                        if server.status == .connected {
                            allowedTools.append("mcp__\(server.name)")
                        }
                    }
                    
                    claudeCommand += "--allowedTools \(allowedTools.joined(separator: ",")) "
                    
                    if let claudeSessionId = project.claudeSessionId, !text.hasPrefix("/") {
                        claudeCommand += "--resume \(claudeSessionId) "
                        print("📌 Resuming existing Claude session: \(claudeSessionId)")
                    } else {
                        print("📌 Starting new Claude session (no session ID or slash command)")
                    }
                    
                    // Add stdin redirection to prevent EBADF error
                    claudeCommand += "< /dev/null"
                    
                    // Escape single quotes in the command by replacing ' with '\''
                    let escapedCommand = claudeCommand.replacingOccurrences(of: "'", with: "'\\''")
                    
                    // Execute with nohup, wrapping the entire command in bash -c with single quotes
                    let nohupCommand = "nohup bash -c '\(escapedCommand)' > \(outputFile) 2>&1 & echo $! > \(pidFile)"
                    _ = try await sshSession.execute(nohupCommand)
                    
                    // Wait for PID file with exponential backoff
                    var pidContent: String?
                    let maxAttempts = 5
                    for attempt in 0..<maxAttempts {
                        let checkCommand = "[ -f \(pidFile) ] && cat \(pidFile) || echo ''"
                        pidContent = try? await sshSession.execute(checkCommand)
                        
                        if let pid = pidContent, !pid.isEmpty {
                            project.nohupProcessId = pid.trimmingCharacters(in: .whitespacesAndNewlines)
                            print("📝 PID file found after \(attempt + 1) attempt(s): \(project.nohupProcessId ?? "")")
                            break
                        }
                        
                        // Exponential backoff: 100ms, 200ms, 400ms, 800ms, 1.6s
                        let delay = UInt64(100_000_000 * (1 << attempt))
                        try await Task.sleep(nanoseconds: delay)
                    }
                    
                    if pidContent?.isEmpty ?? true {
                        print("⚠️ Warning: PID file not created after \(maxAttempts) attempts")
                    }
                    
                    // Start tailing the output file
                    let tailCommand = "tail -f \(outputFile)"
                    let processHandle = try await sshSession.startProcess(tailCommand)
                    
                    // Track file position and nohup info for recovery
                    self.lastReadPositions[project.id] = 0
                    project.lastOutputFilePosition = 0
                    project.outputFilePath = outputFile
                    
                    project.updateLastModified()
                    
                    // Mark connection as active before processing
                    transitionConnectionState(for: project.id, to: .active)
                    
                    // Process streaming output
                    await processStreamingOutput(
                        from: processHandle,
                        outputFile: outputFile,
                        pidFile: pidFile,
                        project: project,
                        server: server,
                        continuation: continuation
                    )
                    
                    
                } catch {
                    // Handle disconnection and recovery
                    if let activeServer = projectContext.activeServer,
                       connectionStates[project.id]?.canRecover ?? false || isRecoverableError(error) {
                        let recoveryFileIdentifier = messageId?.uuidString ?? "\(activeServer.id.uuidString.prefix(8))_\(project.id.uuidString.prefix(8))"
                        await handleConnectionRecovery(
                            project: project,
                            server: activeServer,
                            outputFile: "/tmp/\(recoveryFileIdentifier)_claude.out",
                            pidFile: "/tmp/\(recoveryFileIdentifier)_claude.pid",
                            continuation: continuation,
                            error: error
                        )
                    } else {
                        // Normal error handling
                        cleanupContinuation(for: project.id)
                        continuation.yield(MessageChunk(
                            content: getUserFriendlyErrorMessage(error),
                            isComplete: true,
                            isError: true,
                            metadata: nil
                        ))
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }
    
    /// Clear Claude sessions for the active project
    func clearSessions() {
        guard let project = projectContext.activeProject else { return }
        
        // Clear the session ID
        project.claudeSessionId = nil
        project.updateLastModified()
        
        // Note: The caller should save the project context to persist this change
        // This is already handled in ChatViewModel which saves the modelContext
    }
    
    /// Check for previous session and return recent output
    func checkForPreviousSession(
        project: RemoteProject,
        server: Server
    ) async -> (hasActiveSession: Bool, recentOutput: String?, messageId: UUID?) {
        // Check if we have an active streaming message ID
        guard let messageId = project.activeStreamingMessageId else {
            return (hasActiveSession: false, recentOutput: nil, messageId: nil)
        }
        
        let outputFile = "/tmp/\(messageId.uuidString)_claude.out"
        let pidFile = "/tmp/\(messageId.uuidString)_claude.pid"
        
        do {
            let sshSession = try await sshService.getConnection(for: project, purpose: .claude)
            
            // Check if output file exists and has content
            let checkCommand = "[ -f \(outputFile) ] && [ -s \(outputFile) ] && echo 'EXISTS' || echo 'NO_FILE'"
            let fileCheck = try await sshSession.execute(checkCommand)
            
            if fileCheck.contains("EXISTS") {
                // Get last 10KB of output to show recent conversation
                let tailCommand = "tail -c 10240 \(outputFile)"
                let recentOutput = try await sshSession.execute(tailCommand)
                
                // Check if process is still running
                let isRunning = await isProcessRunning(pidFile: pidFile, sshSession: sshSession)
                
                // If running, get current file size for position tracking
                if isRunning {
                    let sizeCommand = "stat -f%z \(outputFile) 2>/dev/null || stat -c%s \(outputFile)"
                    let currentSize = try await sshSession.execute(sizeCommand)
                    if let size = Int(currentSize.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        lastReadPositions[project.id] = size
                    }
                }
                
                return (hasActiveSession: isRunning, recentOutput: recentOutput, messageId: messageId)
            }
        } catch {
            print("Failed to check for previous session: \(error)")
        }
        
        return (hasActiveSession: false, recentOutput: nil, messageId: nil)
    }
    
    /// Clean up previous session files
    func cleanupPreviousSessionFiles(project: RemoteProject, server: Server, messageId: UUID? = nil) async {
        let fileIdentifier = messageId?.uuidString ?? project.activeStreamingMessageId?.uuidString ?? "\(server.id.uuidString.prefix(8))_\(project.id.uuidString.prefix(8))"
        let outputFile = "/tmp/\(fileIdentifier)_claude.out"
        let pidFile = "/tmp/\(fileIdentifier)_claude.pid"
        
        do {
            let sshSession = try await sshService.getConnection(for: project, purpose: .claude)
            await cleanupNohupFiles(outputFile: outputFile, pidFile: pidFile, sshSession: sshSession)
            
            // Clear the active streaming message ID when cleaning up
            await MainActor.run {
                if messageId != nil {
                    project.activeStreamingMessageId = nil
                }
                project.updateLastModified()
            }
        } catch {
            print("Failed to clean up previous session files: \(error)")
        }
    }
    
    /// Resume streaming from a previous session
    func resumeStreamingFromPreviousSession(
        project: RemoteProject,
        server: Server,
        messageId: UUID
    ) -> AsyncThrowingStream<MessageChunk, Error> {
        AsyncThrowingStream { continuation in
            // Store continuation for recovery
            activeStreamContinuations[project.id] = continuation
            transitionConnectionState(for: project.id, to: .recovering(attempt: 1))
            
            Task {
                do {
                    let outputFile = "/tmp/\(messageId.uuidString)_claude.out"
                    let pidFile = "/tmp/\(messageId.uuidString)_claude.pid"
                    
                    let sshSession = try await sshService.getConnection(for: project, purpose: .claude)
                    
                    // First, read any missed content from last position
                    // Use the persisted position from the project, or fall back to in-memory position
                    let lastPosition = project.lastOutputFilePosition ?? lastReadPositions[project.id] ?? 0
                    
                    // Get current file size to see if there's missed content
                    let sizeCommand = "stat -f%z \(outputFile) 2>/dev/null || stat -c%s \(outputFile)"
                    let currentSizeStr = try await sshSession.execute(sizeCommand)
                    let currentSize = Int(currentSizeStr.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                    
                    print("📝 Resume: Last position: \(lastPosition), Current size: \(currentSize)")
                    
                    // If there's missed content, read it first
                    if currentSize > lastPosition {
                        let missedCommand = "tail -c +\(lastPosition + 1) \(outputFile) | head -c \(currentSize - lastPosition)"
                        let missedOutput = try await sshSession.execute(missedCommand)
                        
                        if !missedOutput.isEmpty {
                            print("📝 Resume: Processing \(missedOutput.count) bytes of missed content")
                            processMissedStreamingOutput(missedOutput, continuation: continuation)
                            
                            // Update position
                            lastReadPositions[project.id] = currentSize
                            project.lastOutputFilePosition = currentSize
                        }
                    }
                    
                    // Now tail from current position for new content
                    let tailCommand = "tail -f -c +\(currentSize + 1) \(outputFile)"
                    let processHandle = try await sshSession.startProcess(tailCommand)
                    
                    // Continue processing new output
                    await processStreamingOutput(
                        from: processHandle,
                        outputFile: outputFile,
                        pidFile: pidFile,
                        project: project,
                        server: server,
                        continuation: continuation
                    )
                } catch {
                    continuation.yield(MessageChunk(
                        content: getUserFriendlyErrorMessage(error),
                        isComplete: true,
                        isError: true,
                        metadata: nil
                    ))
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Private Helper Methods
    
    /// Handle Claude not installed error
    private func handleClaudeNotInstalledError(
        for server: Server?,
        continuation: AsyncThrowingStream<MessageChunk, Error>.Continuation,
        processHandle: ProcessHandle?,
        projectId: UUID?
    ) {
        // Mark Claude as not installed if server is available
        if let server = server {
            Task { @MainActor in
                claudeInstallationStatus[server.id] = false
            }
        }
        
        // Send error chunk
        continuation.yield(MessageChunk(
            content: "Claude Code is not installed on this server. Please install it using:\nnpm install -g @anthropic-ai/claude-code",
            isComplete: true,
            isError: true,
            metadata: ["error": "claude_not_installed"]
        ))
        
        // Clean up if process handle and project ID are available
        if let processHandle = processHandle {
            processHandle.terminate()
        }
        if let projectId = projectId {
            cleanupContinuation(for: projectId)
        }
        
        continuation.finish()
    }
    
    /// Process streaming output with position tracking
    private func processStreamingOutput(
        from processHandle: ProcessHandle,
        outputFile: String,
        pidFile: String,
        project: RemoteProject,
        server: Server,
        continuation: AsyncThrowingStream<MessageChunk, Error>.Continuation
    ) async {
        let lineBuffer = LineBuffer()
        var currentPosition = lastReadPositions[project.id] ?? 0
        var receivedSessionId: String?
        
        // Ensure cleanup on exit
        defer {
            processHandle.terminate()
            cleanupContinuation(for: project.id)
        }
        
        do {
            for try await output in processHandle.outputStream() {
                // Update position using byte count instead of UTF-8 character count
                currentPosition += output.count
                lastReadPositions[project.id] = currentPosition
                project.lastOutputFilePosition = currentPosition
                project.updateLastModified()
                
                // Parse streaming JSON
                let lines = lineBuffer.addData(output)
                for line in lines {
                    // Skip the nohup: ignoring input line
                    if line.contains("nohup: ignoring input") {
                        continue
                    }
                    
                    // Check for Claude not installed error
                    if line.contains("claude: command not found") {
                        handleClaudeNotInstalledError(
                            for: server,
                            continuation: continuation,
                            processHandle: processHandle,
                            projectId: project.id
                        )
                        return
                    }
                    
                    if let chunk = StreamingJSONParser.parseStreamingLine(line) {
                        continuation.yield(enhanceChunkWithAuthError(chunk))
                        
                        // Extract session ID and save immediately
                        if let type = chunk.metadata?["type"] as? String,
                           (type == "system" || type == "result"),
                           let sessionId = chunk.metadata?["sessionId"] as? String {
                            receivedSessionId = sessionId
                            print("📌 Captured session ID: \(sessionId)")
                            
                            // Save session ID immediately to ensure persistence
                            Task { @MainActor in
                                if project.claudeSessionId != sessionId {
                                    project.claudeSessionId = sessionId
                                    project.updateLastModified()
                                    print("📌 Saved session ID to project: \(sessionId)")
                                }
                            }
                        }
                    }
                }
            }
            
            // Process any remaining data
            if let lastLine = lineBuffer.flush() {
                if let chunk = StreamingJSONParser.parseStreamingLine(lastLine) {
                    continuation.yield(chunk)
                }
            }
            
            // Save session ID if received
            if let sessionId = receivedSessionId {
                project.claudeSessionId = sessionId
                project.updateLastModified()
            }
            
            // Clean up files after successful completion
            await cleanupPreviousSessionFiles(project: project, server: server)
            
            continuation.finish()
            
        } catch {
            // Store position for recovery
            lastReadPositions[project.id] = currentPosition
            // Don't rethrow, handle the error here
            continuation.yield(MessageChunk(
                content: getUserFriendlyErrorMessage(error),
                isComplete: true,
                isError: true,
                metadata: nil
            ))
            continuation.finish()
        }
    }
    
    /// Convert error to user-friendly message
    private func getUserFriendlyErrorMessage(_ error: Error) -> String {
        // First check for specific error types
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "No internet connection. Please check your network settings."
            case .timedOut:
                return "Connection timed out. The server may be slow or unreachable."
            case .cannotFindHost:
                return "Cannot find server. Please verify the server address."
            case .cannotConnectToHost:
                return "Cannot connect to server. Please check:\n• Server is online\n• Port is correct\n• Firewall settings"
            default:
                break
            }
        }
        
        let errorString = error.localizedDescription.lowercased()
        
        // EBADF specific error (common with suspended connections)
        if errorString.contains("ebadf") || errorString.contains("bad file descriptor") {
            return "SSH session interrupted. This often happens when:\n" +
                   "• The app was suspended for too long\n" +
                   "• Network connection changed\n" +
                   "• Server terminated the connection\n\n" +
                   "Try sending your message again."
        }
        
        // SSH connection errors
        if errorString.contains("niossh") || errorString.contains("ssh") {
            if errorString.contains("error 1") {
                return "SSH connection failed. Please check:\n• Server is reachable\n• SSH service is running\n• Network connection is stable"
            } else if errorString.contains("authentication") || errorString.contains("permission denied") {
                return "SSH authentication failed. Please check:\n• Username and password/key are correct\n• SSH key has proper permissions\n• Server allows your authentication method"
            } else if errorString.contains("timeout") {
                return "SSH connection timed out. Please check:\n• Server address and port are correct\n• No firewall is blocking the connection\n• Server is online"
            } else if errorString.contains("refused") {
                return "SSH connection refused. Please check:\n• SSH service is running on the server\n• Port number is correct (usually 22)\n• Server firewall allows SSH connections"
            } else if errorString.contains("host key") || errorString.contains("verification failed") {
                return "SSH host key verification failed. This can happen when:\n• Connecting to a new server\n• Server was reinstalled\n• Security settings changed\n\nPlease verify the server identity."
            }
        }
        
        // Network errors
        if errorString.contains("network") || errorString.contains("connection") {
            if errorString.contains("lost") || errorString.contains("reset") {
                return "Connection lost. This may be due to:\n• Unstable network\n• Server restart\n• Timeout from inactivity\n\nPlease try again."
            }
            return "Network error. Please check:\n• Internet connection is stable\n• VPN settings (if applicable)\n• Server is accessible from your network"
        }
        
        // Generic fallback
        return "Connection error: \(error.localizedDescription)\n\nTry:\n• Checking server settings\n• Verifying network connection\n• Restarting the app"
    }
    
    /// Static method to check if an error is recoverable
    @MainActor
    static func checkIfRecoverable(_ error: Error) -> Bool {
        return ClaudeCodeService.shared.isRecoverableError(error)
    }
    
    /// Check if an error is recoverable (network/connection issues)
    private func isRecoverableError(_ error: Error) -> Bool {
        // Get error string once
        let errorString = error.localizedDescription.lowercased()
        
        // Check for specific SSH error types in error description
        if errorString.contains("closed channel") || errorString.contains("already closed") {
            return true
        }
        
        // Check for POSIX errors
        if let posixError = error as? POSIXError {
            switch posixError.code {
            case .ECONNRESET, .ECONNABORTED, .ENETDOWN, .ENETUNREACH, .EHOSTDOWN, .EHOSTUNREACH:
                return true
            case .EPIPE:  // Broken pipe
                return true
            default:
                break
            }
        }
        
        // Check error description patterns
        let recoverablePatterns = [
            "connection", "network", "timeout", "broken pipe",
            "socket", "disconnected", "lost", "reset", "abort",
            "ebadf", "bad file descriptor"
        ]
        
        return recoverablePatterns.contains { errorString.contains($0) }
    }
    
    /// Handle connection recovery after disconnection
    private func handleConnectionRecovery(
        project: RemoteProject,
        server: Server,
        outputFile: String,
        pidFile: String,
        continuation: AsyncThrowingStream<MessageChunk, Error>.Continuation,
        error: Error
    ) async {
        // Track recovery attempts
        let currentAttempt: Int
        if case .recovering(let attempt) = connectionStates[project.id] {
            currentAttempt = attempt + 1
        } else {
            currentAttempt = 1
        }
        
        transitionConnectionState(for: project.id, to: .recovering(attempt: currentAttempt))
        
        do {
            let sshSession = try await sshService.getConnection(for: project, purpose: .claude)
            
            if await isProcessRunning(pidFile: pidFile, sshSession: sshSession) {
                // Process is still running, recover missed output
                let lastPosition = lastReadPositions[project.id] ?? 0
                let missedOutput = try await recoverMissedOutput(
                    for: project,
                    outputFile: outputFile,
                    from: lastPosition,
                    sshSession: sshSession
                )
                
                // Process missed output
                processMissedStreamingOutput(missedOutput, continuation: continuation)
                
                // Resume tailing from the current position
                let currentPosition = lastReadPositions[project.id] ?? missedOutput.count
                let tailCommand = "tail -f -c +\(currentPosition + 1) \(outputFile)"
                let processHandle = try await sshSession.startProcess(tailCommand)
                
                transitionConnectionState(for: project.id, to: .active)
                
                // Continue processing
                await processStreamingOutput(
                    from: processHandle,
                    outputFile: outputFile,
                    pidFile: pidFile,
                    project: project,
                    server: server,
                    continuation: continuation
                )
            } else {
                // Process completed while disconnected
                let fullOutput = try await sshSession.execute("cat \(outputFile)")
                let lastPosition = lastReadPositions[project.id] ?? 0
                let newOutput = String(fullOutput.dropFirst(lastPosition))
                processMissedStreamingOutput(newOutput, continuation: continuation)
                
                // Clean up files after reading completed session
                await cleanupNohupFiles(outputFile: outputFile, pidFile: pidFile, sshSession: sshSession)
                
                continuation.finish()
            }
        } catch {
            transitionConnectionState(for: project.id, to: .failed(error))
            cleanupContinuation(for: project.id)
            continuation.yield(MessageChunk(
                content: getUserFriendlyErrorMessage(error),
                isComplete: true,
                isError: true,
                metadata: nil
            ))
            continuation.finish(throwing: error)
        }
    }
    
    /// Recover missed output after reconnection
    private func recoverMissedOutput(
        for project: RemoteProject,
        outputFile: String,
        from position: Int,
        sshSession: SSHSession
    ) async throws -> String {
        // Read from last position using tail with byte offset
        let readCommand = "tail -c +\(position + 1) \(outputFile)"
        return try await sshSession.execute(readCommand)
    }
    
    /// Process missed streaming output
    private func processMissedStreamingOutput(
        _ output: String,
        continuation: AsyncThrowingStream<MessageChunk, Error>.Continuation
    ) {
        let lines = output.components(separatedBy: .newlines)
        for line in lines where !line.isEmpty {
            // Skip the nohup: ignoring input line
            if line.contains("nohup: ignoring input") {
                continue
            }
            
            // Check for Claude not installed error
            if line.contains("claude: command not found") {
                handleClaudeNotInstalledError(
                    for: nil,  // Server not available in this context
                    continuation: continuation,
                    processHandle: nil,
                    projectId: nil
                )
                return
            }
            
            if let chunk = StreamingJSONParser.parseStreamingLine(line) {
                let enhancedChunk = enhanceChunkWithAuthError(chunk)
                continuation.yield(enhancedChunk)
                
                // Extract and save session ID immediately if found in missed content
                if let type = chunk.metadata?["type"] as? String,
                   (type == "system" || type == "result"),
                   let sessionId = chunk.metadata?["sessionId"] as? String,
                   let project = ProjectContext.shared.activeProject {
                    
                    Task { @MainActor in
                        if project.claudeSessionId != sessionId {
                            project.claudeSessionId = sessionId
                            project.updateLastModified()
                            print("📌 Saved session ID from missed content: \(sessionId)")
                        }
                    }
                }
            }
        }
    }
    
    /// Check if process is still running
    private func isProcessRunning(pidFile: String, sshSession: SSHSession) async -> Bool {
        do {
            let checkCommand = "[ -f \(pidFile) ] && ps -p $(cat \(pidFile)) > /dev/null && echo 'RUNNING' || echo 'NOT_RUNNING'"
            let result = try await sshSession.execute(checkCommand)
            return result.contains("RUNNING")
        } catch {
            return false
        }
    }
    
    /// Clean up nohup output and pid files
    private func cleanupNohupFiles(outputFile: String, pidFile: String, sshSession: SSHSession) async {
        do {
            let cleanupCommand = "rm -f \(outputFile) \(pidFile)"
            _ = try await sshSession.execute(cleanupCommand)
            print("🧹 Cleaned up nohup files: \(outputFile), \(pidFile)")
        } catch {
            print("Failed to clean up nohup files: \(error)")
        }
    }
    
    /// Enhance chunk with authentication error messages
    private func enhanceChunkWithAuthError(_ chunk: MessageChunk) -> MessageChunk {
        guard let type = chunk.metadata?["type"] as? String else { return chunk }
        
        var errorText: String? = nil
        
        // Extract error text based on message type
        if type == "assistant" {
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
            errorText = chunk.metadata?["result"] as? String
        }
        
        // Check for authentication errors
        if let text = errorText,
           (text.contains("Invalid API key") ||
            text.contains("API Error: 401") ||
            text.contains("authentication_error") ||
            text.contains("Invalid bearer token")) {
            
            let authMethod = getCurrentAuthMethod()
            let credentialType = authMethod == .apiKey ? "API key" : "authentication token"
            
            let helpfulMessage = """
            Authentication failed. This could be due to:
            • Incorrect \(credentialType)
            • Outdated Claude CLI version on the server
            
            To fix:
            1. Update Claude CLI on the server with:
               npm install -g @anthropic-ai/claude-code
            
            2. Verify your \(credentialType) is correct in Settings
            """
            
            var updatedMetadata = chunk.metadata ?? [:]
            
            if type == "assistant" {
                updatedMetadata["content"] = [[
                    "type": "text",
                    "text": helpfulMessage
                ]]
            } else if type == "result" {
                updatedMetadata["result"] = helpfulMessage
            }
            
            // Update auth status
            authStatus = .invalidCredentials
            
            return MessageChunk(
                content: helpfulMessage,
                isComplete: chunk.isComplete,
                isError: true,
                metadata: updatedMetadata
            )
        }
        
        return chunk
    }
    
    /// Clean up continuation for a project
    private func cleanupContinuation(for projectId: UUID) {
        if let continuation = activeStreamContinuations[projectId] {
            continuation.finish()
            activeStreamContinuations.removeValue(forKey: projectId)
        }
    }
    
    /// Validate and perform connection state transitions
    @discardableResult
    private func transitionConnectionState(
        for projectId: UUID,
        to newState: ConnectionState
    ) -> Bool {
        guard let currentState = connectionStates[projectId] else {
            connectionStates[projectId] = newState
            print("📊 Connection state for \(projectId): nil -> \(newState.description)")
            return true
        }
        
        // Define valid transitions
        let isValidTransition: Bool
        switch (currentState, newState) {
        case (.idle, .connecting),
             (.connecting, .active),
             (.active, .backgroundSuspended),
             (.backgroundSuspended, .recovering),
             (.recovering, .active),
             (.recovering, .failed),
             (.failed, .connecting),
             (_, .idle):  // Can always go back to idle
            isValidTransition = true
        default:
            isValidTransition = false
        }
        
        if isValidTransition {
            connectionStates[projectId] = newState
            print("📊 Connection state for \(projectId): \(currentState.description) -> \(newState.description)")
            return true
        } else {
            print("⚠️ Invalid state transition for \(projectId): \(currentState.description) -> \(newState.description)")
            return false
        }
    }
    
}

// MARK: - Errors

enum ClaudeError: LocalizedError {
    case noActiveServer
    case notAuthenticated
    case sessionNotFound
    case invalidResponse
    case authenticationRequired
    
    var errorDescription: String? {
        switch self {
        case .noActiveServer:
            return "No active server connection"
        case .notAuthenticated:
            return "Claude Code is not authenticated"
        case .sessionNotFound:
            return "Session not found"
        case .invalidResponse:
            return "Invalid response from Claude Code"
        case .authenticationRequired:
            return "Authentication credentials are required"
        }
    }
}

// MARK: - Timeout Utility

/// Execute an async operation with a timeout
func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        // Add the main operation
        group.addTask {
            try await operation()
        }
        
        // Add timeout task
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        
        // Return the first result (either success or timeout)
        guard let result = try await group.next() else {
            throw TimeoutError()
        }
        
        // Cancel remaining tasks
        group.cancelAll()
        
        return result
    }
}

struct TimeoutError: LocalizedError {
    var errorDescription: String? {
        return "Operation timed out"
    }
}
