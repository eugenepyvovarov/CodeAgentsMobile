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

/// Service for managing Claude Code interactions
@MainActor
class ClaudeCodeService: ObservableObject {
    // MARK: - Singleton
    
    static let shared = ClaudeCodeService()
    
    // MARK: - Properties
    
    
    /// Current authentication status
    @Published var authStatus: ClaudeAuthStatus = .notChecked
    
    /// SSH service reference
    private let sshService = ServiceManager.shared.sshService
    
    /// Project context reference
    private let projectContext = ProjectContext.shared
    
    /// UserDefaults key for auth method preference
    private let claudeAuthMethodKey = "claudeAuthMethod"
    
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Get the current authentication method
    func getCurrentAuthMethod() -> ClaudeAuthMethod {
        let rawValue = UserDefaults.standard.string(forKey: claudeAuthMethodKey) ?? ClaudeAuthMethod.apiKey.rawValue
        return ClaudeAuthMethod(rawValue: rawValue) ?? .apiKey
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
        sessionId: String? = nil
    ) -> AsyncThrowingStream<MessageChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let server = projectContext.activeServer else {
                        throw ClaudeError.noActiveServer
                    }
                    
                    // Get SSH session for this project and purpose
                    let sshSession = try await sshService.getConnection(for: project, purpose: .claude)
                    
                    // Prepare the message
                    let escapedMessage = text
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                        .replacingOccurrences(of: "\n", with: "\\n")
                    
                    // First, let's test with a simple echo command to verify streaming works
                    let testSimpleCommand = false // Set to true to test
                    
                    var command: String
                    let debugSteps = false // Enable debug to test Claude installation
                    
                    if testSimpleCommand {
                        // Simple test command that outputs immediately
                        command = "echo 'Line 1: Testing SSH streaming' && echo 'Line 2: Buffer should catch this' && echo 'Line 3: All output captured'"
                    } else {
                        // Build the Claude command - let's test with a simple version first
                        
                        if debugSteps {
                            // Test each step separately to find where it hangs
                            command = "echo '=== Testing Claude setup ===' && "
                            command += "echo 'Step 1: Current directory' && pwd && "
                            command += "echo 'Step 2: Changing to project directory' && "
                            command += "cd '\(project.path)' 2>&1 && pwd && "
                            command += "echo 'Step 3: Setting API key' && "
                            command += try buildAuthExportCommand()
                            command += "echo 'Step 4: Checking Claude installation' && "
                            command += "which claude && echo 'Claude found at above path' || echo 'Claude NOT found in PATH' && "
                            command += "echo 'Step 5: Checking Claude version' && "
                            command += "claude --version || echo 'Claude version check failed' && "
                            command += "echo 'Step 6: Testing Claude help' && "
                            command += "claude --help | head -5 || echo 'Claude help failed' && "
                            command += "echo 'Step 7: Running Claude with message \"\(escapedMessage)\"' && "
                            command += "claude --print \"\(escapedMessage)\" --output-format stream-json --verbose "
                            command += "--allowedTools Bash,Write,Edit,MultiEdit,NotebookEdit,Read,LS,Grep,Glob 2>&1"
                        } else {
                            // Use streaming JSON with verbose and allowedTools
                            command = "cd '\(project.path)' && "
                            command += try buildAuthExportCommand()
                            // Full command with streaming, verbose, and allowedTools
                            // CRITICAL: DO NOT MODIFY ANY FLAGS IN THIS COMMAND!
                            // --print: REQUIRED to run in non-interactive mode (without it, Claude hangs waiting for input)
                            // --output-format stream-json: REQUIRED for streaming JSON responses that we parse
                            // --verbose: REQUIRED to get session IDs and detailed output
                            // --allowedTools: REQUIRED to specify which tools Claude can use
                            // Removing ANY of these flags will break the integration!
                            command += "claude --print \"\(escapedMessage)\" "
                            command += "--output-format stream-json --verbose "
                            command += "--allowedTools Bash,Write,Edit,MultiEdit,NotebookEdit,Read,LS,Grep,Glob "
                            
                            // Add continuation flag if needed
                            if let claudeSessionId = project.claudeSessionId, !text.hasPrefix("/") {
                                // Use --resume with the saved session ID
                                command += "--resume \(claudeSessionId) "
                            }
                            
                            // Add stderr redirection at the end
                            command += "2>&1"
                        }
                    }
                    
                    print("📤 Executing Claude command:")
                    print("📋 Command: \(command)")
                    
                    // Start process for streaming output
                    let processHandle = try await sshSession.startProcess(command)
                    let lineBuffer = LineBuffer()
                    var receivedSessionId: String?
                    
                    // Read output as it arrives with timeout detection
                    do {
                        var hasReceivedOutput = false
                        let startTime = Date()
                        
                        // Create a timeout task
                        let timeoutTask = Task {
                            try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                            if !hasReceivedOutput {
                                print("⚠️ No output received after 10 seconds")
                                print("🔍 Possible issues:")
                                print("   - Claude CLI not installed or not in PATH")
                                print("   - Command syntax error")
                                print("   - SSH session issues")
                            }
                        }
                        
                        for try await chunk in processHandle.outputStream() {
                            hasReceivedOutput = true
                            timeoutTask.cancel()
                            
                            print("📥 Received chunk (\(chunk.count) chars)")
                            print("📄 Raw chunk: \(chunk)")
                            
                            let lines = lineBuffer.addData(chunk)
                            for line in lines {
                                print("📄 Processing line: \(line)")
                                
                                // Parse JSON line using StreamingJSONParser
                                if let parsedChunk = StreamingJSONParser.parseStreamingLine(line) {
                                    // Check for authentication errors and enhance the message
                                    var enhancedChunk = parsedChunk
                                    if let type = parsedChunk.metadata?["type"] as? String {
                                        var errorText: String? = nil
                                        
                                        // Check for errors in different places based on message type
                                        if type == "assistant" {
                                            if let content = parsedChunk.metadata?["content"] as? [[String: Any]] {
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
                                            // Result messages may have error text in the "result" field
                                            errorText = parsedChunk.metadata?["result"] as? String
                                        }
                                        
                                        // Check if we have an authentication error
                                        if let text = errorText,
                                           (text.contains("Invalid API key") || 
                                            text.contains("API Error: 401") || 
                                            text.contains("authentication_error") ||
                                            text.contains("Invalid bearer token")) {
                                            
                                            // Replace with more helpful error message
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
                                            
                                            var updatedMetadata = parsedChunk.metadata ?? [:]
                                            
                                            if type == "assistant" {
                                                updatedMetadata["content"] = [[
                                                    "type": "text",
                                                    "text": helpfulMessage
                                                ]]
                                            } else if type == "result" {
                                                updatedMetadata["result"] = helpfulMessage
                                            }
                                            
                                            // Also update the content property for backward compatibility
                                            enhancedChunk = MessageChunk(
                                                content: helpfulMessage,
                                                isComplete: parsedChunk.isComplete,
                                                isError: true,
                                                metadata: updatedMetadata
                                            )
                                            
                                            // Update auth status
                                            authStatus = .invalidCredentials
                                        }
                                    }
                                    
                                    continuation.yield(enhancedChunk)
                                    
                                    // Extract session ID from system messages
                                    if let type = enhancedChunk.metadata?["type"] as? String,
                                       type == "system",
                                       let sessionId = enhancedChunk.metadata?["sessionId"] as? String {
                                        receivedSessionId = sessionId
                                        print("📌 Captured session ID: \(sessionId)")
                                    }
                                    
                                    // Check for result message to capture session ID
                                    if let type = enhancedChunk.metadata?["type"] as? String,
                                       type == "result",
                                       let sessionId = enhancedChunk.metadata?["sessionId"] as? String {
                                        receivedSessionId = sessionId
                                        print("📌 Captured session ID from result: \(sessionId)")
                                    }
                                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                                    // Fallback for non-JSON lines (shouldn't happen with Claude Code)
                                    print("⚠️ Non-JSON line: \(line)")
                                }
                            }
                        }
                        
                        // Process any remaining data in the buffer
                        if let lastLine = lineBuffer.flush() {
                            print("📄 Processing final line: \(lastLine)")
                            if let parsedChunk = StreamingJSONParser.parseStreamingLine(lastLine) {
                                continuation.yield(parsedChunk)
                            } else if !lastLine.trimmingCharacters(in: .whitespaces).isEmpty {
                                print("⚠️ Non-JSON final line: \(lastLine)")
                            }
                        }
                    } catch {
                        print("❌ Stream error: \(error)")
                        continuation.yield(MessageChunk(
                            content: "Stream error: \(error.localizedDescription)",
                            isComplete: true,
                            isError: true,
                            metadata: nil
                        ))
                    }
                    
                    // Save the session ID to the project if we received one
                    if let sessionId = receivedSessionId {
                        project.claudeSessionId = sessionId
                        // Note: The caller should save the project to persist this change
                    }
                    
                    continuation.finish()
                    
                } catch {
                    continuation.yield(MessageChunk(
                        content: error.localizedDescription,
                        isComplete: true,
                        isError: true,
                        metadata: nil
                    ))
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    /// Clear Claude sessions for the active project
    func clearSessions() {
        guard let project = projectContext.activeProject else { return }
        
        // Clear the session ID
        project.claudeSessionId = nil
        
        // Note: The caller should save the project context to persist this change
        // This is already handled in ChatViewModel which saves the modelContext
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
