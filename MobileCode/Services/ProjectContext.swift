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

/// Manages the active project context across the app
@MainActor
class ProjectContext: ObservableObject {
    // MARK: - Singleton
    
    static let shared = ProjectContext()
    
    // MARK: - Properties
    
    /// Currently active project
    @Published var activeProject: RemoteProject?
    
    /// Reference to server manager for server lookups
    private let serverManager = ServerManager.shared
    
    // MARK: - Initialization
    
    private init() {
        // Private initializer for singleton
    }
    
    // MARK: - Methods
    
    /// Set the active project
    /// - Parameter project: The project to activate
    func setActiveProject(_ project: RemoteProject) {
        // Clear any previous project connections if switching projects
        if let currentProject = activeProject, currentProject.id != project.id {
            clearActiveProject()
        }
        
        // Set the new active project
        activeProject = project
        
        print("✅ Activated agent: \(project.displayTitle)")
    }
    
    /// Clear the active project
    func clearActiveProject() {
        if let project = activeProject {
            // Close all connections for this project
            ServiceManager.shared.sshService.closeConnections(projectId: project.id)
        }
        
        activeProject = nil
    }
    
    /// Get the full path for the active project
    var activeProjectPath: String? {
        activeProject?.path
    }
    
    /// Check if a project is currently active
    func isProjectActive(_ project: RemoteProject) -> Bool {
        activeProject?.id == project.id
    }
    
    /// Get the working directory for terminal/file operations
    var workingDirectory: String {
        activeProjectPath ?? "/root/projects"
    }
    
    /// Get the server for the active project
    var activeServer: Server? {
        guard let project = activeProject else { return nil }
        return serverManager.server(withId: project.serverId)
    }
}
