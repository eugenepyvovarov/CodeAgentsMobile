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
            let chunk: MessageChunk?
            switch response.type {
            case "system":
                chunk = parseSystemMessage(response)
                
            case "assistant":
                chunk = parseAssistantMessage(response)
                
            case "user":
                chunk = parseUserMessage(response)
                
            case "result":
                chunk = parseResultMessage(response)
                
            case "tool_use", "tool_result":
                chunk = parseStreamingLineFallback(line, data: data)
                
            default:
                chunk = nil
            }
            
            let fallbackChunk = chunk ?? parseStreamingLineFallback(line, data: data)
            return attachOriginalJSON(line, to: fallbackChunk)
            
        } catch {
            if let fallbackChunk = parseStreamingLineFallback(line, data: data) {
                return attachOriginalJSON(line, to: fallbackChunk)
            }
            
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

    private static func parseStreamingLineFallback(_ line: String, data: Data) -> MessageChunk? {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
              let json = jsonObject as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }
        
        switch type {
        case "system":
            var metadata: [String: Any] = [
                "type": "system",
                "subtype": json["subtype"] as? String ?? "unknown"
            ]
            if let tools = json["tools"] as? [String] {
                metadata["tools"] = tools
            }
            if let sessionId = json["session_id"] as? String {
                metadata["sessionId"] = sessionId
            }
            return MessageChunk(content: "", isComplete: false, isError: false, metadata: metadata)
            
        case "assistant":
            let blocks = filteredContentBlocks(from: json, allowedTypes: ["text", "tool_use"])
            guard !blocks.isEmpty else { return nil }
            return MessageChunk(
                content: "",
                isComplete: false,
                isError: false,
                metadata: [
                    "type": "assistant",
                    "role": "assistant",
                    "content": blocks
                ]
            )
            
        case "user":
            let blocks = filteredContentBlocks(from: json, allowedTypes: ["tool_result"])
            guard !blocks.isEmpty else { return nil }
            return MessageChunk(
                content: "",
                isComplete: false,
                isError: false,
                metadata: [
                    "type": "user",
                    "role": "user",
                    "content": blocks
                ]
            )
            
        case "tool_use":
            let block = toolUseBlock(from: json)
            return MessageChunk(
                content: "",
                isComplete: false,
                isError: false,
                metadata: [
                    "type": "assistant",
                    "role": "assistant",
                    "content": [block]
                ]
            )
            
        case "tool_result":
            let block = toolResultBlock(from: json)
            return MessageChunk(
                content: "",
                isComplete: false,
                isError: json["is_error"] as? Bool ?? false,
                metadata: [
                    "type": "user",
                    "role": "user",
                    "content": [block]
                ]
            )

        case "tool_permission":
            var metadata: [String: Any] = ["type": "tool_permission"]
            if let permissionId = json["permission_id"] as? String {
                metadata["permissionId"] = permissionId
            }
            if let toolName = json["tool_name"] as? String {
                metadata["toolName"] = toolName
            }
            if let input = json["input"] as? [String: Any] {
                metadata["input"] = input
            }
            if let suggestions = json["permission_suggestions"] as? [String] {
                metadata["suggestions"] = suggestions
            }
            if let blockedPath = json["blocked_path"] as? String {
                metadata["blockedPath"] = blockedPath
            }
            return MessageChunk(
                content: "",
                isComplete: false,
                isError: false,
                metadata: metadata
            )

        case "result":
            var metadata: [String: Any] = ["type": "result"]
            if let subtype = json["subtype"] as? String {
                metadata["subtype"] = subtype
            }
            if let sessionId = json["session_id"] as? String {
                metadata["sessionId"] = sessionId
            }
            if let durationMs = json["duration_ms"] {
                metadata["duration_ms"] = durationMs
            }
            if let totalCostUsd = json["total_cost_usd"] {
                metadata["total_cost_usd"] = totalCostUsd
            }
            if let result = json["result"] {
                metadata["result"] = result
            }
            return MessageChunk(
                content: "",
                isComplete: true,
                isError: json["is_error"] as? Bool ?? false,
                metadata: metadata
            )
            
        default:
            return nil
        }
    }

    private static func attachOriginalJSON(_ line: String, to chunk: MessageChunk?) -> MessageChunk? {
        guard let chunk = chunk else { return nil }
        var metadata = chunk.metadata ?? [:]
        metadata["originalJSON"] = line
        if let normalized = normalizedStorageLine(from: line) {
            metadata["normalizedJSON"] = normalized
        }
        return MessageChunk(
            content: chunk.content,
            isComplete: chunk.isComplete,
            isError: chunk.isError,
            metadata: metadata
        )
    }

    private static func normalizedStorageLine(from line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
              let json = jsonObject as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        switch type {
        case "tool_use":
            let block = toolUseBlock(from: json)
            let normalized: [String: Any] = [
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [block]
                ]
            ]
            return serializeNormalized(normalized)

        case "tool_result":
            let block = toolResultBlock(from: json)
            let normalized: [String: Any] = [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": [block]
                ]
            ]
            return serializeNormalized(normalized)

        default:
            return nil
        }
    }

    private static func serializeNormalized(_ json: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private static func filteredContentBlocks(from json: [String: Any], allowedTypes: Set<String>) -> [[String: Any]] {
        let blocks = extractContentBlocks(from: json)
        return blocks.filter { block in
            guard let type = block["type"] as? String else { return false }
            return allowedTypes.contains(type)
        }
    }

    private static func extractContentBlocks(from json: [String: Any]) -> [[String: Any]] {
        guard let message = json["message"] as? [String: Any] else { return [] }
        if let content = message["content"] as? [Any] {
            return content.compactMap { item in
                if let dict = item as? [String: Any] {
                    return dict
                }
                if let text = item as? String {
                    return ["type": "text", "text": text]
                }
                return nil
            }
        }
        if let text = message["content"] as? String {
            return [["type": "text", "text": text]]
        }
        return []
    }

    private static func toolUseBlock(from json: [String: Any]) -> [String: Any] {
        var block: [String: Any] = ["type": "tool_use"]
        if let id = json["id"] {
            block["id"] = id
        }
        if let name = json["name"] {
            block["name"] = name
        }
        if let input = json["input"] {
            block["input"] = input
        }
        return block
    }

    private static func toolResultBlock(from json: [String: Any]) -> [String: Any] {
        var block: [String: Any] = ["type": "tool_result"]
        if let toolUseId = json["tool_use_id"] {
            block["tool_use_id"] = toolUseId
        }
        if let content = json["content"] {
            block["content"] = content
        }
        if let isError = json["is_error"] as? Bool {
            block["is_error"] = isError
        }
        return block
    }
}
