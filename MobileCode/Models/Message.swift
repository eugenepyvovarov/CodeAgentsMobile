//
//  Message.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//

import Foundation
import SwiftData

@Model
final class Message {
    var id: UUID = UUID()
    var content: String = ""
    var role: MessageRole = MessageRole.user
    var timestamp: Date = Date()
    var projectId: UUID?
    
    // Store original JSON response from Claude for future UI rendering
    var originalJSON: Data?
    
    init(content: String = "", role: MessageRole = .user, projectId: UUID? = nil, originalJSON: Data? = nil) {
        self.id = UUID()
        self.content = content
        self.role = role
        self.projectId = projectId
        self.timestamp = Date()
        self.originalJSON = originalJSON
    }
    
    // Computed property to decode original JSON when needed
    var originalResponse: [String: Any]? {
        guard let data = originalJSON else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }
    
    // Computed property to parse message structure (legacy single message)
    var structuredContent: StructuredMessageContent? {
        guard let data = originalJSON else { return nil }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(StructuredMessageContent.self, from: data)
        } catch {
            // Try parsing as array for new format
            if let messages = structuredMessages, let first = messages.first {
                return first
            }
            print("Failed to decode structured content: \(error)")
            return nil
        }
    }
    
    // New property to handle array of structured messages
    var structuredMessages: [StructuredMessageContent]? {
        guard let data = originalJSON else { return nil }
        
        // Try to parse as array of JSON lines
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        let lines = jsonString.split(separator: "\n").map { String($0) }
        
        var messages: [StructuredMessageContent] = []
        
        for line in lines {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8) else { continue }
            
            do {
                let decoder = JSONDecoder()
                let message = try decoder.decode(StructuredMessageContent.self, from: lineData)
                messages.append(message)
            } catch {
                print("Failed to decode line: \(error)")
            }
        }
        
        return messages.isEmpty ? nil : messages
    }
    
    // Helper to determine message type
    var messageType: MessageType {
        guard let structured = structuredContent else {
            return .plainText
        }
        
        switch structured.type {
        case "user":
            return .user
        case "assistant":
            return .assistant
        case "system":
            return .system
        case "result":
            return .result
        default:
            return .plainText
        }
    }
    
    // Display function that returns text content for UI rendering
    func displayText() -> String {
        // If we have original JSON, return its pretty-printed representation
        if let data = originalJSON,
           let json = try? JSONSerialization.jsonObject(with: data, options: []),
           let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]),
           let prettyString = String(data: prettyData, encoding: .utf8) {
            return prettyString
        }
        
        // Otherwise return the plain text content
        return content
    }
}

enum MessageRole: Codable {
    case user
    case assistant
}

enum MessageType {
    case plainText
    case user
    case assistant
    case system
    case result
}

// Extension for Identifiable conformance
extension Message: Identifiable {}
