//
//  ServerProvider.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-08-12.
//

import Foundation
import SwiftData

@Model
final class ServerProvider {
    var id = UUID()
    var providerType: String // "digitalocean" or "hetzner"
    var name: String // Display name
    var apiTokenKey: String // Keychain reference
    var createdAt = Date()
    
    init(providerType: String, name: String) {
        self.providerType = providerType
        self.name = name
        self.apiTokenKey = "provider_token_\(UUID().uuidString)"
    }
}