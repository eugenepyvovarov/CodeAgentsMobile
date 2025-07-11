//
//  MessageContent.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-05.
//

import Foundation

// MARK: - Structured Message Content

struct StructuredMessageContent: Decodable {
    let type: String
    let message: MessageContent?
    let subtype: String?
    let data: [String: Any]?
    
    // Result message properties
    let durationMs: Int?
    let durationApiMs: Int?
    let isError: Bool?
    let numTurns: Int?
    let sessionId: String?
    let totalCostUsd: Double?
    let usage: UsageInfo?
    let result: String?
    
    enum CodingKeys: String, CodingKey {
        case type, message, subtype, data
        case durationMs = "duration_ms"
        case durationApiMs = "duration_api_ms"
        case isError = "is_error"
        case numTurns = "num_turns"
        case sessionId = "session_id"
        case totalCostUsd = "total_cost_usd"
        case usage, result
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        message = try container.decodeIfPresent(MessageContent.self, forKey: .message)
        subtype = try container.decodeIfPresent(String.self, forKey: .subtype)
        
        // Handle generic data field
        if let dataValue = try? container.decodeIfPresent([String: Any].self, forKey: .data) {
            data = dataValue
        } else {
            data = nil
        }
        
        // Result message properties
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        durationApiMs = try container.decodeIfPresent(Int.self, forKey: .durationApiMs)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError)
        numTurns = try container.decodeIfPresent(Int.self, forKey: .numTurns)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        totalCostUsd = try container.decodeIfPresent(Double.self, forKey: .totalCostUsd)
        usage = try container.decodeIfPresent(UsageInfo.self, forKey: .usage)
        result = try container.decodeIfPresent(String.self, forKey: .result)
    }
}

// MARK: - Message Content

struct MessageContent: Decodable {
    let role: String
    let content: ContentType
    
    enum ContentType {
        case text(String)
        case blocks([ContentBlock])
    }
    
    enum CodingKeys: String, CodingKey {
        case role, content
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        
        // Claude always sends content as an array, even for simple text
        if let blocks = try? container.decode([ContentBlock].self, forKey: .content) {
            content = .blocks(blocks)
        } else if let textContent = try? container.decode(String.self, forKey: .content) {
            // Backward compatibility for old messages
            content = .text(textContent)
        } else {
            // Try to decode as empty array for edge cases
            content = .blocks([])
        }
    }
}

// MARK: - Content Blocks

enum ContentBlock: Decodable {
    case text(TextBlock)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)
    
    enum CodingKeys: String, CodingKey {
        case type
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        
        switch type {
        case "text":
            let block = try TextBlock(from: decoder)
            self = .text(block)
        case "tool_use":
            let block = try ToolUseBlock(from: decoder)
            self = .toolUse(block)
        case "tool_result":
            let block = try ToolResultBlock(from: decoder)
            self = .toolResult(block)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown content block type: \(type)"
            )
        }
    }
}

// MARK: - Block Types

struct TextBlock: Decodable {
    let type: String
    let text: String
}

struct ToolUseBlock: Decodable {
    let type: String
    let id: String
    let name: String
    let input: [String: Any]
    
    enum CodingKeys: String, CodingKey {
        case type, id, name, input
    }
    
    init(type: String, id: String, name: String, input: [String: Any]) {
        self.type = type
        self.id = id
        self.name = name
        self.input = input
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        
        // Decode input as generic dictionary
        // First try the direct approach for simple cases
        do {
            if let jsonObject = try container.decodeIfPresent([String: AnyCodable].self, forKey: .input) {
                input = jsonObject.mapValues { $0.value }
            } else {
                input = [:]
            }
        } catch {
            // Fallback to manual JSON parsing
            if let inputData = try? container.decode(Data.self, forKey: .input),
               let inputDict = try? JSONSerialization.jsonObject(with: inputData, options: []) as? [String: Any] {
                input = inputDict
            } else {
                input = [:]
            }
        }
    }
}

struct ToolResultBlock: Decodable {
    let type: String
    let toolUseId: String
    let content: String
    let isError: Bool
    
    enum CodingKeys: String, CodingKey {
        case type
        case toolUseId = "tool_use_id"
        case content
        case isError = "is_error"
    }
}

// MARK: - Supporting Types

struct UsageInfo: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let thinkingTokens: Int?
    
    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case thinkingTokens = "thinking_tokens"
    }
}

// MARK: - JSON Decoding Helpers

struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else if container.decodeNil() {
            value = NSNull()
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode value")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        case is NSNull:
            try container.encodeNil()
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: container.codingPath, debugDescription: "Cannot encode value"))
        }
    }
}

// MARK: - JSON Decoding Extensions

extension KeyedDecodingContainer {
    func decode(_ type: [String: Any].Type, forKey key: K) throws -> [String: Any] {
        let data = try self.decode(Data.self, forKey: key)
        guard let dict = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "Cannot decode [String: Any] from data"
            )
        }
        return dict
    }
    
    func decodeIfPresent(_ type: [String: Any].Type, forKey key: K) throws -> [String: Any]? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }
}