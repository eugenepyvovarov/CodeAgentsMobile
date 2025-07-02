//
//  ProjectContext.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-01.
//
//  Purpose: Manages the active project context across the app
//  - Tracks currently active project
//  - Automatically manages server connections when switching projects
//  - Provides project path context to all views
//

import Foundation
import SwiftUI
import SwiftData

/// Manages the active project context and coordinates with ConnectionManager
@MainActor
class ProjectContext: ObservableObject {
    // MARK: - Singleton
    
    static let shared = ProjectContext()
    
    // MARK: - Properties
    
    /// Currently active project
    @Published var activeProject: Project?
    
    /// Whether we're in the process of activating a project
    @Published var isActivating: Bool = false
    
    /// Error message if project activation fails
    @Published var activationError: String?
    
    /// Reference to connection manager
    private let connectionManager = ConnectionManager.shared
    
    /// Model context for updating project data
    private var modelContext: ModelContext?
    
    // MARK: - Initialization
    
    private init() {
        // Private initializer for singleton
    }
    
    // MARK: - Configuration
    
    /// Set the model context for database operations
    func configure(with modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    // MARK: - Methods
    
    /// Set the active project and connect to its server
    /// - Parameter project: The project to activate
    func setActiveProject(_ project: Project) async {
        // Clear any previous error
        activationError = nil
        isActivating = true
        
        do {
            // Find the server for this project
            guard let modelContext = modelContext else {
                throw ProjectError.noModelContext
            }
            
            let serverId = project.serverId
            let descriptor = FetchDescriptor<Server>(
                predicate: #Predicate { server in
                    server.id == serverId
                }
            )
            
            let servers = try modelContext.fetch(descriptor)
            guard let server = servers.first else {
                throw ProjectError.serverNotFound
            }
            
            // Check if we need to connect to a different server
            if connectionManager.activeServer?.id != server.id {
                // Disconnect from current server if connected
                if connectionManager.isConnected {
                    connectionManager.disconnect()
                }
                
                // Connect to the project's server
                await connectionManager.connect(to: server)
                
                // Check if connection was successful
                if !connectionManager.isConnected {
                    throw ProjectError.connectionFailed(
                        connectionManager.connectionError ?? "Unknown connection error"
                    )
                }
            }
            
            // Update project timestamps
            project.lastOpened = Date()
            project.lastAccessed = Date()
            
            // Set as active project
            activeProject = project
            
            // Update ConnectionManager's active project
            connectionManager.setActiveProject(project)
            
            // Save changes
            try modelContext.save()
            
            print("✅ Activated project: \(project.name) on server: \(server.name)")
            
        } catch {
            activationError = error.localizedDescription
            print("❌ Failed to activate project: \(error)")
        }
        
        isActivating = false
    }
    
    /// Clear the active project
    func clearActiveProject() {
        activeProject = nil
        activationError = nil
        connectionManager.setActiveProject(nil)
    }
    
    /// Get the full path for the active project
    var activeProjectPath: String? {
        activeProject?.path
    }
    
    /// Check if a project is currently active
    func isProjectActive(_ project: Project) -> Bool {
        activeProject?.id == project.id
    }
    
    /// Get the working directory for terminal/file operations
    var workingDirectory: String {
        activeProjectPath ?? "/root/projects"
    }
}

// MARK: - Errors

enum ProjectError: LocalizedError {
    case noModelContext
    case serverNotFound
    case connectionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .noModelContext:
            return "Database context not configured"
        case .serverNotFound:
            return "Server not found for this project"
        case .connectionFailed(let message):
            return "Failed to connect to server: \(message)"
        }
    }
}