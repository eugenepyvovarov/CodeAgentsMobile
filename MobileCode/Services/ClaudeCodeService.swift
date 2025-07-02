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

/// Authentication status for Claude Code
enum ClaudeAuthStatus {
    case authenticated
    case missingAPIKey
    case invalidAPIKey
    case notChecked
}

/// Represents a chat session with Claude Code
struct ClaudeSession {
    let id: String  // Our internal ID
    let projectId: UUID
    let startedAt: Date
    var lastMessageAt: Date
    var messageCount: Int = 0
    var claudeSessionId: String?  // Claude's actual session ID
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
    
    /// Active sessions by project ID
    private var sessions: [UUID: ClaudeSession] = [:]
    
    /// Current authentication status
    @Published var authStatus: ClaudeAuthStatus = .notChecked
    
    /// SSH service reference
    private let sshService = ServiceManager.shared.sshService
    
    /// Connection manager reference
    private let connectionManager = ConnectionManager.shared
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Check if Claude Code is installed and authenticated
    func checkClaudeStatus(on server: Server) async -> (installed: Bool, authenticated: Bool, error: String?) {
        do {
            let session = try await sshService.connect(to: server)
            
            // Use command -v which is more portable than which
            let commandCheck = try await session.execute("command -v claude > /dev/null 2>&1 && echo 'found' || echo 'not found'")
            
            if commandCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "not found" {
                return (false, false, nil)  // Claude not installed, but not an error
            }
            
            // Claude exists, assume it's installed correctly
            // Don't check version as it might hang
            
            // Don't check authentication here - it might hang
            // We'll check when actually trying to use it
            authStatus = .notChecked
            return (true, false, nil)
            
        } catch {
            return (false, false, error.localizedDescription)
        }
    }
    
    /// Start or resume a session for a project
    func getOrCreateSession(for project: Project) -> ClaudeSession {
        if let existingSession = sessions[project.id] {
            return existingSession
        }
        
        let newSession = ClaudeSession(
            id: UUID().uuidString,
            projectId: project.id,
            startedAt: Date(),
            lastMessageAt: Date()
        )
        
        sessions[project.id] = newSession
        return newSession
    }
    
    /// Send a message to Claude Code and stream the response
    func sendMessage(
        _ text: String,
        in project: Project,
        sessionId: String? = nil
    ) -> AsyncThrowingStream<MessageChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let server = connectionManager.activeServer else {
                        throw ClaudeError.noActiveServer
                    }
                    
                    let sshSession = try await sshService.connect(to: server)
                    
                    // Get or create session
                    var session = getOrCreateSession(for: project)
                    
                    // Get API key from keychain
                    let apiKey: String
                    do {
                        apiKey = try KeychainManager.shared.retrieveAPIKey()
                        print("✅ Retrieved API key from keychain (length: \(apiKey.count))")
                    } catch {
                        print("❌ No API key found in keychain")
                        continuation.yield(MessageChunk(
                            content: "No API key found. Please set your Anthropic API key in Settings.",
                            isComplete: true,
                            isError: true,
                            metadata: nil
                        ))
                        continuation.finish()
                        return
                    }
                    
                    // Prepare the command
                    let projectPath = project.path
                    let escapedMessage = text
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                        .replacingOccurrences(of: "\n", with: "\\n")
                    
                    // Build a single command that sets everything up in one shell
                    var claudeCommand = "claude -p"
                    
                    // Add appropriate flags
                    if !text.hasPrefix("/") && session.messageCount > 0 {
                        // For continuing conversations, use --continue to continue the most recent conversation
                        claudeCommand += " --continue"
                    }
                    
                    // Add the message
                    claudeCommand += " \"\(escapedMessage)\""
                    
                    // Add output format for JSON parsing
                    claudeCommand += " --output-format json"
                    
                    // Add verbose flag for more detailed output
                    claudeCommand += " --verbose"
                    
                    // Pre-approve common tools to avoid permission prompts
                    // Include Bash for command execution, file operations, and notebook editing
                    claudeCommand += " --allowedTools Bash,Write,Edit,MultiEdit,NotebookEdit,Read"
                    
                    // Combine everything into one command (no timeout!)
                    // Simplified command without wrapper
                    // Redirect stdin from /dev/null to ensure Claude doesn't wait for input
                    let command = """
                    cd '\(projectPath)' && \
                    export ANTHROPIC_API_KEY="\(apiKey)" && \
                    \(claudeCommand) < /dev/null
                    """
                    
                    // Debug: Show the command being executed
                    print("🚀 Executing command: \(command)")
                    
                    // Execute command
                    print("⏳ Waiting for Claude response...")
                    let output = try await sshSession.execute(command)
                    
                    // Debug: Show full raw output
                    print("📥 Raw output length: \(output.count) characters")
                    print("📥 Full output:\n\(output)")
                    print("📥 End of output")
                    
                    // Check if we got any output at all
                    guard !output.isEmpty else {
                        print("❌ No output received from Claude")
                        continuation.yield(MessageChunk(
                            content: "No response received from Claude. The command may have timed out or failed silently.",
                            isComplete: true,
                            isError: true,
                            metadata: nil
                        ))
                        continuation.finish()
                        return
                    }
                    
                    // Parse the output
                    print("🔍 Checking output conditions...")
                    print("  - Is empty: \(output.isEmpty)")
                    print("  - Contains timeout: \(output.contains("timeout: sending signal"))")
                    print("  - Contains command not found: \(output.contains("command not found"))")
                    print("  - Contains ANTHROPIC_API_KEY: \(output.contains("ANTHROPIC_API_KEY"))")
                    print("  - Contains error: \(output.contains("error"))")
                    print("  - Contains not authenticated: \(output.contains("not authenticated"))")
                    print("  - Contains type:system: \(output.contains("\"type\":\"system\""))")
                    
                    if output.isEmpty || output.contains("timeout: sending signal") {
                        print("❌ Triggering timeout error")
                        continuation.yield(MessageChunk(
                            content: "Request timed out. Claude might be taking too long to respond or there might be an authentication issue.",
                            isComplete: true,
                            isError: true,
                            metadata: nil
                        ))
                    } else if output.contains("command not found") {
                        print("❌ Triggering command not found error")
                        continuation.yield(MessageChunk(
                            content: "Claude Code is not installed. Please install it on the server using: npm install -g @anthropic-ai/claude-code",
                            isComplete: true,
                            isError: true,
                            metadata: nil
                        ))
                    } else if !output.contains("\"type\":\"system\"") && ((output.contains("ANTHROPIC_API_KEY") && output.contains("error")) || output.contains("not authenticated")) {
                        print("❌ Triggering authentication error")
                        // Only treat as auth error if it's not a valid Claude JSON response
                        continuation.yield(MessageChunk(
                            content: "Claude Code needs authentication. Please set your API key or authenticate on the server.",
                            isComplete: true,
                            isError: true,
                            metadata: nil
                        ))
                    } else {
                        print("✅ Proceeding to JSON parsing")
                        // Try to parse as JSON response
                        if let data = output.data(using: .utf8) {
                        print("📊 Attempting to parse JSON response...")
                        do {
                            // First try to parse as array (verbose format)
                            if output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
                                print("📊 Detected array format JSON")
                                let responses = try JSONDecoder().decode([ClaudeResponse].self, from: data)
                                print("✅ Parsed \(responses.count) Claude responses (array format)")
                                
                                // Debug: Print all response types
                                for (index, response) in responses.enumerated() {
                                    print("  Response \(index): type=\(response.type), has result=\(response.result != nil)")
                                }
                                
                                // Process all responses to show verbose output
                                var fullContent = ""
                                var hasToolUse = false
                                var turnCount = 0
                                var sessionInfo = ""
                                
                                for (index, response) in responses.enumerated() {
                                    switch response.type {
                                    case "system":
                                        if response.subtype == "init" {
                                            // Show initialization info
                                            var initInfo = "🚀 **Claude initialized**\n"
                                            if let sessionId = response.sessionId {
                                                sessionInfo = sessionId
                                                initInfo += "📍 Session ID: `\(sessionId.prefix(8))...`\n"
                                            }
                                            if let tools = response.tools, !tools.isEmpty {
                                                initInfo += "📦 Available tools: \(tools.count) tools\n"
                                                // Show tools in groups
                                                let fileTools = tools.filter { ["Read", "Write", "Edit", "MultiEdit"].contains($0) }
                                                let searchTools = tools.filter { ["Glob", "Grep", "LS"].contains($0) }
                                                let execTools = tools.filter { ["Bash", "Task"].contains($0) }
                                                let otherTools = tools.filter { !fileTools.contains($0) && !searchTools.contains($0) && !execTools.contains($0) }
                                                
                                                if !fileTools.isEmpty {
                                                    initInfo += "  • File ops: \(fileTools.joined(separator: ", "))\n"
                                                }
                                                if !searchTools.isEmpty {
                                                    initInfo += "  • Search: \(searchTools.joined(separator: ", "))\n"
                                                }
                                                if !execTools.isEmpty {
                                                    initInfo += "  • Execute: \(execTools.joined(separator: ", "))\n"
                                                }
                                                if !otherTools.isEmpty {
                                                    initInfo += "  • Other: \(otherTools.joined(separator: ", "))\n"
                                                }
                                            }
                                            fullContent += initInfo + "\n"
                                        }
                                        
                                    case "assistant":
                                        turnCount += 1
                                        if let message = response.message {
                                            // Show turn marker
                                            fullContent += "**[Turn \(turnCount)]**\n"
                                            
                                            // Check for tool use
                                            if let content = message.content {
                                                for item in content {
                                                    if case .toolUse(let toolUse) = item {
                                                        hasToolUse = true
                                                        fullContent += "\n🔧 **Tool: \(toolUse.name)**\n"
                                                        
                                                        // Show tool details based on tool type
                                                        fullContent += "🆔 Tool ID: `\(toolUse.id.suffix(8))`\n"
                                                        
                                                        // Show specific details for common tools
                                                        switch toolUse.name {
                                                        case "Bash":
                                                            fullContent += "💻 Executing shell command\n"
                                                        case "Read":
                                                            fullContent += "📖 Reading file\n"
                                                        case "Write":
                                                            fullContent += "✏️ Writing file\n"
                                                        case "Edit", "MultiEdit":
                                                            fullContent += "✂️ Editing file\n"
                                                        case "LS":
                                                            fullContent += "📂 Listing directory\n"
                                                        case "Grep":
                                                            fullContent += "🔍 Searching in files\n"
                                                        default:
                                                            break
                                                        }
                                                    } else if case .text(let text) = item {
                                                        if !text.isEmpty {
                                                            fullContent += "\n💭 Claude: \(text)\n"
                                                        }
                                                    }
                                                }
                                            }
                                            
                                            // Show token usage if available
                                            if let usage = message.usage as? [String: Any] {
                                                if let inputTokens = usage["input_tokens"] as? Int,
                                                   let outputTokens = usage["output_tokens"] as? Int {
                                                    fullContent += "📊 Tokens: \(inputTokens) in, \(outputTokens) out\n"
                                                }
                                            }
                                        }
                                        
                                    case "user":
                                        // Show tool results
                                        if let message = response.message,
                                           let content = message.content {
                                            for item in content {
                                                if case .toolResult(let toolResult) = item {
                                                    fullContent += "\n✅ **Tool result** (ID: `\(toolResult.toolUseId.suffix(8))`)\n"
                                                    // Show a preview of the result
                                                    if let resultContent = toolResult.content {
                                                        let preview = resultContent.prefix(200)
                                                        if resultContent.count > 200 {
                                                            fullContent += "📄 \(preview)...\n"
                                                            fullContent += "   *(Result truncated, \(resultContent.count) chars total)*\n"
                                                        } else {
                                                            fullContent += "📄 \(resultContent)\n"
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        
                                    case "result":
                                        // Show final result with metadata
                                        fullContent += "\n---\n\n"
                                        
                                        if let duration = response.durationMs {
                                            fullContent += "⏱️ **Completed in \(duration)ms**\n"
                                        }
                                        
                                        if let cost = response.totalCostUsd {
                                            let costStr = String(format: "%.6f", cost)
                                            fullContent += "💰 **Cost: $\(costStr)**\n"
                                        }
                                        
                                        // For result type, usage might be at the top level
                                        // We'll need to parse it properly later if needed
                                        fullContent += "\n"
                                        
                                        fullContent += "\n**Final response:**\n\n"
                                        
                                        if let result = response.result {
                                            fullContent += result
                                        }
                                        
                                        // Store the session ID if available
                                        if let sessionId = response.sessionId {
                                            session.claudeSessionId = sessionId
                                            print("📝 Stored Claude session ID: \(sessionId)")
                                        }
                                        
                                    default:
                                        break
                                    }
                                }
                                
                                // Yield the complete content
                                if !fullContent.isEmpty {
                                    continuation.yield(MessageChunk(
                                        content: fullContent,
                                        isComplete: false,
                                        isError: false,
                                        metadata: nil
                                    ))
                                } else {
                                    print("⚠️ No content extracted from responses")
                                }
                            } else {
                                // Try single response format
                                let response = try JSONDecoder().decode(ClaudeResponse.self, from: data)
                                print("✅ Parsed single Claude response: type=\(response.type)")
                                
                                if let result = response.result {
                                    continuation.yield(MessageChunk(
                                        content: result,
                                        isComplete: false,
                                        isError: response.isError ?? false,
                                        metadata: nil
                                    ))
                                } else if let message = response.message, let textContent = message.textContent, !textContent.isEmpty {
                                    continuation.yield(MessageChunk(
                                        content: textContent,
                                        isComplete: false,
                                        isError: false,
                                        metadata: nil
                                    ))
                                }
                            }
                        } catch let decodingError as DecodingError {
                            print("❌ JSON Decoding Error: \(decodingError)")
                            
                            var errorMessage = "JSON Parsing Error: "
                            
                            // Build detailed error message
                            switch decodingError {
                            case .keyNotFound(let key, let context):
                                errorMessage += "Missing key '\(key.stringValue)'"
                                print("  Missing key: \(key.stringValue)")
                                print("  Context: \(context.debugDescription)")
                                print("  CodingPath: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
                            case .typeMismatch(let type, let context):
                                errorMessage += "Type mismatch for \(type)"
                                print("  Type mismatch for type: \(type)")
                                print("  Context: \(context.debugDescription)")
                                print("  CodingPath: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
                            case .valueNotFound(let type, let context):
                                errorMessage += "Value not found for \(type)"
                                print("  Value not found for type: \(type)")
                                print("  Context: \(context.debugDescription)")
                                print("  CodingPath: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
                            case .dataCorrupted(let context):
                                errorMessage += "Data corrupted"
                                print("  Data corrupted")
                                print("  Context: \(context.debugDescription)")
                                print("  CodingPath: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
                            @unknown default:
                                errorMessage += "Unknown decoding error"
                                print("  Unknown decoding error")
                            }
                            
                            // Try to extract the first 500 chars of the output for debugging
                            let preview = String(output.prefix(500))
                            print("  Output preview: \(preview)")
                            
                            // Show error in UI
                            continuation.yield(MessageChunk(
                                content: "\(errorMessage)\n\nDebug: Check console for detailed error information.",
                                isComplete: true,
                                isError: true,
                                metadata: nil
                            ))
                        } catch {
                            print("❌ General parsing error: \(error)")
                            // Show error in UI
                            continuation.yield(MessageChunk(
                                content: "Parsing Error: \(error.localizedDescription)\n\nDebug: Check console for detailed error information.",
                                isComplete: true,
                                isError: true,
                                metadata: nil
                            ))
                        }
                    } else {
                        // Not valid UTF-8, treat as error
                        continuation.yield(MessageChunk(
                            content: "Invalid response encoding",
                            isComplete: true,
                            isError: true,
                            metadata: nil
                        ))
                    }
                    }
                    
                    // Update session
                    session.messageCount += 1
                    session.lastMessageAt = Date()
                    sessions[project.id] = session
                    
                    print("✅ Finished processing Claude response, sending completion chunk")
                    
                    // Send completion chunk
                    continuation.yield(MessageChunk(
                        content: "",
                        isComplete: true,
                        isError: false,
                        metadata: ["sessionId": session.id]
                    ))
                    
                    continuation.finish()
                    print("✅ Stream finished")
                    
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
    
    /// Set API key environment variable
    func setAPIKey(_ apiKey: String, on server: Server) async throws {
        let session = try await sshService.connect(to: server)
        
        // Add to .bashrc for persistence
        let command = """
        echo 'export ANTHROPIC_API_KEY="\(apiKey)"' >> ~/.bashrc && \
        export ANTHROPIC_API_KEY="\(apiKey)"
        """
        
        _ = try await session.execute(command)
        authStatus = .authenticated
    }
    
    /// Clear all sessions
    func clearSessions() {
        sessions.removeAll()
    }
    
    // MARK: - Private Methods
    
    /// Parse streaming JSON output from Claude Code
    private func parseStreamingJSON(_ output: String) -> [MessageChunk] {
        var chunks: [MessageChunk] = []
        
        // First try to parse the entire output as JSON
        if let data = output.data(using: .utf8) {
            do {
                // Try to decode as ClaudeResponse
                let response = try JSONDecoder().decode(ClaudeResponse.self, from: data)
                
                if let result = response.result {
                    chunks.append(MessageChunk(
                        content: result,
                        isComplete: false,
                        isError: response.isError ?? false,
                        metadata: ["type": response.type, "sessionId": response.sessionId ?? ""]
                    ))
                }
                
                return chunks
            } catch {
                // Not a single JSON object, try line by line
            }
        }
        
        // Split by newlines to handle multiple JSON objects or mixed output
        let lines = output.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            
            // Skip common SSH/shell output
            if trimmed.contains("Last login") || 
               trimmed.contains("Welcome to") ||
               trimmed.starts(with: "[") && trimmed.contains("]$") {
                continue
            }
            
            // Try to parse as JSON
            if let data = trimmed.data(using: .utf8) {
                do {
                    let response = try JSONDecoder().decode(ClaudeResponse.self, from: data)
                    
                    if let result = response.result {
                        chunks.append(MessageChunk(
                            content: result,
                            isComplete: false,
                            isError: response.isError ?? false,
                            metadata: ["type": response.type, "sessionId": response.sessionId ?? ""]
                        ))
                    }
                } catch {
                    // If not valid JSON, treat as plain text
                    if trimmed.contains("error") || trimmed.contains("Error") {
                        chunks.append(MessageChunk(
                            content: trimmed,
                            isComplete: false,
                            isError: true,
                            metadata: nil
                        ))
                    } else if !trimmed.isEmpty {
                        chunks.append(MessageChunk(
                            content: trimmed,
                            isComplete: false,
                            isError: false,
                            metadata: nil
                        ))
                    }
                }
            }
        }
        
        return chunks
    }
}

// MARK: - Errors

enum ClaudeError: LocalizedError {
    case noActiveServer
    case notAuthenticated
    case sessionNotFound
    case invalidResponse
    
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
        }
    }
}