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
    var authMethodType: String = "password"
    var createdAt: Date = Date()
    var lastConnected: Date?
    var isDefault: Bool = false
    
    init(name: String, host: String, port: Int = 22, username: String, authMethodType: String = "password") {
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethodType = authMethodType
    }
}