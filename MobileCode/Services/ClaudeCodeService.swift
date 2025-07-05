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
    
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public Methods
    
    
    
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
                    
                    // Build the Claude command
                    var command = "cd '\(project.path)' && "
                    command += "export ANTHROPIC_API_KEY=\"\(try KeychainManager.shared.retrieveAPIKey())\" && "
                    command += "claude --output-format stream-json --verbose "
                    command += "--allowedTools Bash,Write,Edit,MultiEdit,NotebookEdit,Read,LS,Grep,Glob "
                    
                    // Add continuation flag if needed
                    if let claudeSessionId = project.claudeSessionId, !text.hasPrefix("/") {
                        // Use --resume with the saved session ID
                        command += "--resume \(claudeSessionId) "
                    }
                    
                    // Add the message
                    command += "\"\(escapedMessage)\""
                    
                    print("📤 Executing Claude command")
                    
                    // Execute and get output
                    let output = try await sshSession.execute(command)
                    
                    print("📥 Received output (\(output.count) chars)")
                    
                    // Parse streaming JSON output line by line
                    let lines = output.components(separatedBy: .newlines)
                        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    
                    var receivedSessionId: String?
                    
                    for line in lines {
                        if let messageChunk = StreamingJSONParser.parseStreamingLine(line) {
                            // Extract session ID if present
                            if let metadata = messageChunk.metadata,
                               let sessionId = metadata["sessionId"] as? String,
                               !sessionId.isEmpty {
                                receivedSessionId = sessionId
                            }
                            continuation.yield(messageChunk)
                        }
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