//
//  Server.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//

import Foundation
import SwiftData

@Model
final class Server {
    var id = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var username: String
    var authMethodType: String = "password" // "password" or "key"
    var sshKeyId: UUID? // Reference to SSHKey when authMethodType is "key"
    // Password is stored securely in Keychain Services
    // SSH private keys are stored separately in SSHKey model
    var createdAt: Date = Date()
    var lastConnected: Date?
    
    /// Default directory path for projects on this server
    /// nil means it hasn't been detected yet (will use ~/projects when detected)
    var defaultProjectsPath: String?
    
    /// Last custom path selected by the user for creating projects
    /// nil means the user hasn't selected a custom path yet
    var lastUsedProjectPath: String?
    
    init(name: String, host: String, port: Int = 22, username: String, authMethodType: String = "password") {
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethodType = authMethodType
        self.defaultProjectsPath = nil // Will be auto-detected on first use
        self.lastUsedProjectPath = nil // Will be set when user selects custom path
    }
}
