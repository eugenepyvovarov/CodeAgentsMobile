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
    
    init(name: String, serverId: UUID, basePath: String = "/root/projects") {
        self.id = UUID()
        self.name = name
        self.path = "\(basePath)/\(name)"
        self.serverId = serverId
        self.lastModified = Date()
        self.createdAt = Date()
    }
    
    func updateLastModified() {
        lastModified = Date()
    }
}