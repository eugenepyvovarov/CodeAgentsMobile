//
//  StreamingJSONParser.swift
//  CodeAgentsMobile
//
//  Purpose: Parse streaming JSON output from Claude Code
//  - Handles line-by-line parsing
//  - Converts JSON to MessageChunk format
//  - Formats tool usage for display
//

import Foundation

/// Parser for Claude Code streaming JSON output
class StreamingJSONParser {
    
    /// Parse a single streaming JSON line into a MessageChunk
    static func parseStreamingLine(_ line: String) -> MessageChunk? {
        guard let data = line.data(using: .utf8) else { return nil }
        
        do {
            let response = try JSONDecoder().decode(ClaudeStreamingResponse.self, from: data)
            
            // Convert streaming response to MessageChunk based on type
            switch response.type {
            case "system":
                return parseSystemMessage(response)
                
            case "assistant":
                return parseAssistantMessage(response)
                
            case "user":
                return parseUserMessage(response)
                
            case "result":
                return parseResultMessage(response)
                
            default:
                // Unknown message type, ignore
                return nil
            }
            
        } catch {
            // Log parsing error but don't show to user
            SSHLogger.log("Failed to parse streaming line: \(error)", level: .debug)
            SSHLogger.log("Line content: \(line)", level: .verbose)
            return nil
        }
    }
    
    // MARK: - Private Parsing Methods
    
    private static func parseSystemMessage(_ response: ClaudeStreamingResponse) -> MessageChunk? {
        guard response.subtype == "init" else { return nil }
        
        // Initial system message with tool list
        var content = "🚀 **Claude initialized**\n"
        if let tools = response.tools, !tools.isEmpty {
            content += "🛠️ Available tools: \(tools.joined(separator: ", "))\n"
        }
        
        return MessageChunk(
            content: content,
            isComplete: false,
            isError: false,
            metadata: ["type": "system", "subtype": "init"]
        )
    }
    
    private static func parseAssistantMessage(_ response: ClaudeStreamingResponse) -> MessageChunk? {
        guard let message = response.message,
              let contents = message.content else { return nil }
        
        var fullContent = ""
        for content in contents {
            switch content {
            case .text(let text):
                fullContent += text
                
            case .toolUse(let toolUse):
                fullContent += formatToolUse(toolUse)
                
            case .toolResult(_):
                // Tool results come in user messages, not assistant
                break
                
            case .unknown:
                break
            }
        }
        
        guard !fullContent.isEmpty else { return nil }
        
        return MessageChunk(
            content: fullContent,
            isComplete: false,
            isError: false,
            metadata: ["type": "assistant", "role": "assistant"]
        )
    }
    
    private static func parseUserMessage(_ response: ClaudeStreamingResponse) -> MessageChunk? {
        guard let message = response.message,
              let contents = message.content else { return nil }
        
        var fullContent = ""
        for content in contents {
            if case .toolResult(let toolResult) = content {
                fullContent += formatToolResult(toolResult)
            }
        }
        
        guard !fullContent.isEmpty else { return nil }
        
        return MessageChunk(
            content: fullContent,
            isComplete: false,
            isError: false,
            metadata: ["type": "user", "role": "user"]
        )
    }
    
    private static func parseResultMessage(_ response: ClaudeStreamingResponse) -> MessageChunk? {
        return MessageChunk(
            content: response.result ?? "",
            isComplete: true,
            isError: response.isError ?? false,
            metadata: ["type": "result", "sessionId": response.sessionId ?? ""]
        )
    }
    
    // MARK: - Formatting Helpers
    
    private static func formatToolUse(_ toolUse: ClaudeContent.ToolUse) -> String {
        var content = "\n🔧 **Using tool:** `\(toolUse.name)`\n"
        if let input = toolUse.input {
            content += "📥 Input: `\(String(describing: input))`\n"
        }
        return content
    }
    
    private static func formatToolResult(_ toolResult: ClaudeContent.ToolResult) -> String {
        var content = "\n✅ **Tool result** (ID: `\(toolResult.toolUseId.suffix(8))`)\n"
        
        if let resultContent = toolResult.content {
            let preview = resultContent.prefix(200)
            if resultContent.count > 200 {
                content += "📄 \(preview)...\n"
                content += "   *(Result truncated, \(resultContent.count) chars total)*\n"
            } else {
                content += "📄 \(resultContent)\n"
            }
        }
        
        return content
    }
}