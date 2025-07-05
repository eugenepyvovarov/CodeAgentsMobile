//
//  ServerManager.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-05.
//
//  Purpose: Manages server configurations
//  - Loads servers from SwiftData
//  - Provides access to server list
//  - Single responsibility: server data management
//

import Foundation
import SwiftUI
import SwiftData

/// Manages server configurations across the app
@MainActor
class ServerManager: ObservableObject {
    // MARK: - Singleton
    
    static let shared = ServerManager()
    
    // MARK: - Properties
    
    /// List of all servers
    @Published var servers: [Server] = []
    
    // MARK: - Initialization
    
    private init() {
        // Private initializer for singleton
    }
    
    // MARK: - Methods
    
    /// Load servers from SwiftData
    /// - Parameter modelContext: The model context to fetch servers from
    func loadServers(from modelContext: ModelContext) {
        do {
            let descriptor = FetchDescriptor<Server>(sortBy: [SortDescriptor(\Server.name)])
            let fetchedServers = try modelContext.fetch(descriptor)
            servers = fetchedServers
            SSHLogger.log("Loaded \(fetchedServers.count) servers", level: .info)
        } catch {
            SSHLogger.log("Failed to load servers: \(error)", level: .error)
            servers = []
        }
    }
    
    /// Find a server by ID
    /// - Parameter id: Server ID
    /// - Returns: Server if found
    func server(withId id: UUID) -> Server? {
        servers.first { $0.id == id }
    }
    
    /// Update server list (for manual refresh)
    /// - Parameter servers: New server list
    func updateServers(_ servers: [Server]) {
        self.servers = servers
    }
}