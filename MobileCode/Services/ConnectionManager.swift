//
//  ConnectionManager.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//
//  Purpose: Manages active server connections
//  - Tracks current active server
//  - Notifies ViewModels of connection changes
//  - Handles connection state
//

import Foundation
import SwiftUI
import SwiftData

/// Manages server connections across the app
@MainActor
class ConnectionManager: ObservableObject {
    // MARK: - Singleton
    
    static let shared = ConnectionManager()
    
    // MARK: - Properties
    
    /// List of all servers
    @Published var servers: [Server] = []
    
    /// Currently active server
    @Published var activeServer: Server?
    
    /// Currently active project
    @Published var activeProject: Project?
    
    /// Connection status
    @Published var isConnected: Bool = false
    
    /// Connection error message
    @Published var connectionError: String?
    
    /// SSH Service reference
    private let sshService = ServiceManager.shared.sshService
    
    // MARK: - Initialization
    
    private init() {
        // Private initializer for singleton
    }
    
    /// Load servers from SwiftData
    /// - Parameter modelContext: The model context to fetch servers from
    func loadServers(from modelContext: ModelContext) {
        do {
            let descriptor = FetchDescriptor<Server>(sortBy: [SortDescriptor(\Server.name)])
            let fetchedServers = try modelContext.fetch(descriptor)
            servers = fetchedServers
        } catch {
            print("❌ Failed to load servers: \(error)")
            servers = []
        }
    }
    
    // MARK: - Methods
    
    /// Connect to a server
    /// - Parameter server: Server to connect to
    func connect(to server: Server) async {
        connectionError = nil
        
        do {
            _ = try await sshService.connect(to: server)
            activeServer = server
            isConnected = true
            
            // Update last connected time
            server.lastConnected = Date()
            
            print("✅ Connected to \(server.name)")
        } catch {
            connectionError = error.localizedDescription
            isConnected = false
            
            print("❌ Connection failed: \(error)")
        }
    }
    
    /// Disconnect from current server
    func disconnect() {
        if let server = activeServer {
            Task {
                await sshService.disconnect(from: server.id)
            }
        }
        
        activeServer = nil
        activeProject = nil
        isConnected = false
        connectionError = nil
        
        print("🔌 Disconnected")
    }
    
    /// Set the active project
    /// - Parameter project: Project to set as active
    func setActiveProject(_ project: Project?) {
        activeProject = project
    }
    
    /// Get current server ID
    var currentServerId: UUID? {
        activeServer?.id
    }
}