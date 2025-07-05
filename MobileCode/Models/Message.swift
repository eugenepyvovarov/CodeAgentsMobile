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

// Extension for Identifiable conformance
extension Message: Identifiable {}
