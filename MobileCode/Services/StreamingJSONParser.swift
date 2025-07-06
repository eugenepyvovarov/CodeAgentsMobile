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
            var chunk: MessageChunk?
            switch response.type {
            case "system":
                chunk = parseSystemMessage(response)
                
            case "assistant":
                chunk = parseAssistantMessage(response)
                
            case "user":
                chunk = parseUserMessage(response)
                
            case "result":
                chunk = parseResultMessage(response)
                
            default:
                // Unknown message type, ignore
                return nil
            }
            
            // Add original JSON data to metadata
            if var chunk = chunk {
                var metadata = chunk.metadata ?? [:]
                metadata["originalJSON"] = line
                return MessageChunk(
                    content: chunk.content,
                    isComplete: chunk.isComplete,
                    isError: chunk.isError,
                    metadata: metadata
                )
            }
            
            return chunk
            
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
        
        // Return raw data for UI to format
        var metadata: [String: Any] = [
            "type": "system",
            "subtype": response.subtype ?? "unknown"
        ]
        
        if let tools = response.tools {
            metadata["tools"] = tools
        }
        
        if let sessionId = response.sessionId {
            metadata["sessionId"] = sessionId
        }
        
        return MessageChunk(
            content: "", // No pre-formatted content
            isComplete: false,
            isError: false,
            metadata: metadata
        )
    }
    
    private static func parseAssistantMessage(_ response: ClaudeStreamingResponse) -> MessageChunk? {
        guard let message = response.message,
              let contents = message.content else { return nil }
        
        // Convert content to metadata for structured display
        var contentBlocks: [[String: Any]] = []
        
        for content in contents {
            switch content {
            case .text(let text):
                contentBlocks.append([
                    "type": "text",
                    "text": text
                ])
                
            case .toolUse(let toolUse):
                var block: [String: Any] = [
                    "type": "tool_use",
                    "id": toolUse.id,
                    "name": toolUse.name
                ]
                if let input = toolUse.input {
                    block["input"] = input
                }
                contentBlocks.append(block)
                
            case .toolResult(_):
                // Tool results come in user messages, not assistant
                break
                
            case .unknown:
                break
            }
        }
        
        guard !contentBlocks.isEmpty else { return nil }
        
        return MessageChunk(
            content: "", // No pre-formatted content
            isComplete: false,
            isError: false,
            metadata: [
                "type": "assistant",
                "role": "assistant",
                "content": contentBlocks
            ]
        )
    }
    
    private static func parseUserMessage(_ response: ClaudeStreamingResponse) -> MessageChunk? {
        guard let message = response.message,
              let contents = message.content else { return nil }
        
        // Convert content to metadata for structured display
        var contentBlocks: [[String: Any]] = []
        
        for content in contents {
            switch content {
            case .text(let text):
                contentBlocks.append([
                    "type": "text",
                    "text": text
                ])
                
            case .toolResult(let toolResult):
                var block: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": toolResult.toolUseId,
                    "is_error": false  // ToolResult doesn't have isError field
                ]
                if let content = toolResult.content {
                    block["content"] = content
                }
                contentBlocks.append(block)
                
            case .toolUse(_):
                // Tool uses come in assistant messages, not user
                break
                
            case .unknown:
                break
            }
        }
        
        guard !contentBlocks.isEmpty else { return nil }
        
        return MessageChunk(
            content: "", // No pre-formatted content
            isComplete: false,
            isError: false,
            metadata: [
                "type": "user",
                "role": "user",
                "content": contentBlocks
            ]
        )
    }
    
    private static func parseResultMessage(_ response: ClaudeStreamingResponse) -> MessageChunk? {
        var metadata: [String: Any] = ["type": "result"]
        
        if let subtype = response.subtype {
            metadata["subtype"] = subtype
        }
        if let sessionId = response.sessionId {
            metadata["sessionId"] = sessionId
        }
        if let durationMs = response.durationMs {
            metadata["duration_ms"] = durationMs
        }
        // These fields don't exist in ClaudeStreamingResponse
        // if let durationApiMs = response.durationApiMs {
        //     metadata["duration_api_ms"] = durationApiMs
        // }
        // if let numTurns = response.numTurns {
        //     metadata["num_turns"] = numTurns
        // }
        if let totalCostUsd = response.totalCostUsd {
            metadata["total_cost_usd"] = totalCostUsd
        }
        if let usage = response.usage {
            // Usage is a generic dictionary, pass it through as-is
            metadata["usage"] = usage
        }
        if let result = response.result {
            metadata["result"] = result
        }
        
        return MessageChunk(
            content: "", // No pre-formatted content
            isComplete: true,
            isError: response.isError ?? false,
            metadata: metadata
        )
    }
}