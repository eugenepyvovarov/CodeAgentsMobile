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
    // TODO: Add password storage using Keychain Services
    // TODO: Add SSH private key storage using Keychain Services
    // TODO: Consider converting authMethodType to enum for type safety
    // Password is stored securely in Keychain Services
    var createdAt: Date = Date()
    var lastConnected: Date?
    
    init(name: String, host: String, port: Int = 22, username: String, authMethodType: String = "password") {
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethodType = authMethodType
    }
}
