//
//  Project.swift
//  CodeAgentsMobile
//
//
//  Purpose: Data model for remote project representation
//

import Foundation
import SwiftData

/// Represents a project on a remote server
@Model
final class RemoteProject {
    var id = UUID()
    var name: String
    var displayName: String?
    var path: String
    var lastModified: Date
    var createdAt: Date
    
    /// Server ID where this project exists
    var serverId: UUID
    
    // Session management
    var claudeSessionId: String?
    var hasActiveClaudeStream: Bool = false
    
    var terminalSessionId: String?
    var hasActiveTerminal: Bool = false
    
    var hasActiveFileOperation: Bool = false
    
    // Nohup tracking properties
    var lastOutputFilePosition: Int?
    var nohupProcessId: String?
    var outputFilePath: String?
    
    // Active streaming message tracking
    var activeStreamingMessageId: UUID?

    // Proxy SSE event tracking
    var proxyLastEventId: Int?

    // Proxy conversation identifier
    var proxyConversationId: String?

    // Proxy conversation group identifier
    var proxyConversationGroupId: String?

    // Proxy agent identifier (stable across app reinstalls, stored in <agent>/.claude/codeagents.json)
    var proxyAgentId: String?

    // Agent env vars sync status (proxy-only)
    var envVarsPendingSync: Bool = false
    var envVarsLastSyncedAt: Date?
    var envVarsLastSyncError: String?

    // Proxy version tracking for sync decisions
    var proxyVersion: String?
    var proxyStartedAt: String?

    // MARK: - Unread Tracking (per-device)

    /// Conversation identifier associated with unread cursors.
    /// Stored separately from transport state to avoid coupling unread tracking to proxy plumbing.
    var unreadConversationId: String?

    /// Latest absolute unread cursor learned from push and/or proxy headers.
    var lastKnownUnreadCursor: Int = 0

    /// Cursor value considered "read" (advanced when the user views the chat and scrolls to bottom).
    var lastReadUnreadCursor: Int = 0
    
    init(name: String, displayName: String? = nil, serverId: UUID, basePath: String = "/root/projects") {
        self.id = UUID()
        self.name = name
        self.displayName = displayName
        self.path = "\(basePath)/\(name)"
        self.serverId = serverId
        self.lastModified = Date()
        self.createdAt = Date()
    }
    
    func updateLastModified() {
        lastModified = Date()
    }

    var displayTitle: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return name
    }

    var unreadCount: Int {
        max(0, lastKnownUnreadCursor - lastReadUnreadCursor)
    }

    var unreadBadgeText: String? {
        let count = unreadCount
        guard count > 0 else { return nil }
        if count >= 100 {
            return "99+"
        }
        return "\(count)"
    }
}
