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

    // Proxy event ID for ordering/deduping replayed events
    var proxyEventId: Int?
    
    // Track if message streaming is complete
    var isComplete: Bool = true
    
    // Track if message is currently streaming
    var isStreaming: Bool = false

    /// JSON-encoded `[ChatMessageAttachment]` for local previews and upload status.
    var attachmentsJSON: Data?

    /// App-generated error notice (upload failure, etc.) — rendered as an error banner, not an assistant reply.
    var isLocalError: Bool = false

    /// Strong finality proof for canonical OpenCode unread cursors. UI cleanup may
    /// stop a spinner, but only terminal SSE or REST `time.completed` sets this.
    var openCodeRuntimeFinalized: Bool = false
    
    init(content: String = "", role: MessageRole = .user, projectId: UUID? = nil, originalJSON: Data? = nil, isComplete: Bool = true, isStreaming: Bool = false) {
        self.id = UUID()
        self.content = content
        self.role = role
        self.projectId = projectId
        self.timestamp = Date()
        self.originalJSON = originalJSON
        self.isComplete = isComplete
        self.isStreaming = isStreaming
        self.isLocalError = false
        self.openCodeRuntimeFinalized = false
    }

    /// Whether this message should use the dedicated error banner UI.
    var presentsAsLocalError: Bool {
        if isLocalError { return true }
        // Legacy rows created before `isLocalError` existed.
        guard role == .assistant,
              !hasChatAttachments,
              structuredMessages == nil,
              structuredContent == nil,
              !isStreaming else {
            return false
        }
        return ChatErrorPresentation.looksLikeLegacyLocalError(content)
    }

    var chatAttachments: [ChatMessageAttachment] {
        get { ChatMessageAttachmentCodec.decode(attachmentsJSON) }
        set { attachmentsJSON = ChatMessageAttachmentCodec.encode(newValue) }
    }

    var hasChatAttachments: Bool {
        !(attachmentsJSON?.isEmpty ?? true)
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

    /// Returns an unmanaged copy for SwiftUI rendering.
    ///
    /// ExyteChat can retain row views briefly after a persisted message is removed. Rendering an
    /// unmanaged copy prevents those outgoing rows from reading invalidated SwiftData backing storage.
    func detachedForRendering() -> Message {
        let copy = Message(
            content: content,
            role: role,
            projectId: projectId,
            originalJSON: originalJSON,
            isComplete: isComplete,
            isStreaming: isStreaming
        )
        copy.id = id
        copy.timestamp = timestamp
        copy.proxyEventId = proxyEventId
        copy.attachmentsJSON = attachmentsJSON
        copy.isLocalError = isLocalError
        return copy
    }

    func fallbackContentBlocks() -> [ContentBlock] {
        guard let data = originalJSON,
              let raw = String(data: data, encoding: .utf8) else {
            return []
        }

        let lines = raw.split(separator: "\n").map(String.init)
        var blocks: [ContentBlock] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let jsonObject = try? JSONSerialization.jsonObject(with: lineData, options: []) else {
                continue
            }

            if let dict = jsonObject as? [String: Any] {
                blocks.append(contentsOf: Message.extractBlocks(from: dict))
            } else if let array = jsonObject as? [Any] {
                blocks.append(contentsOf: Message.extractBlocks(fromContent: array))
            }
        }

        return blocks.filter { block in
            if case .unknown = block {
                return false
            }
            return true
        }
    }

    private static func extractBlocks(from json: [String: Any]) -> [ContentBlock] {
        if let type = json["type"] as? String,
           (type == "tool_use" || type == "tool_result"),
           let block = ContentBlock.fromAny(json) {
            return [block]
        }
        if let message = json["message"] as? [String: Any] {
            return extractBlocks(fromContent: message["content"])
        }
        if let content = json["content"] {
            return extractBlocks(fromContent: content)
        }
        return []
    }

    private static func extractBlocks(fromContent content: Any?) -> [ContentBlock] {
        if let array = content as? [Any] {
            return array.compactMap { ContentBlock.fromAny($0) }
        }
        if let dict = content as? [String: Any],
           let block = ContentBlock.fromAny(dict) {
            return [block]
        }
        if let text = content as? String {
            return [.text(TextBlock(type: "text", text: text))]
        }
        return []
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
