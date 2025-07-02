//
//  ProjectsViewModel.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//
//  Purpose: Manages project list state and operations
//  - Handles loading projects from SwiftData
//  - Manages favorites and recent projects
//  - Provides search functionality
//

import SwiftUI
import SwiftData
import Observation

/// ViewModel for managing the projects list
/// Keeps things simple - just handles the data and basic operations
@MainActor
@Observable
class ProjectsViewModel {
    // MARK: - Properties
    
    /// Loading state for UI feedback
    var isLoading = false
    
    /// Error message if something goes wrong
    var errorMessage: String?
    
    /// Currently selected project for navigation
    var selectedProject: Project?
    
    // MARK: - Methods
    
    /// Toggle favorite status for a project
    /// - Parameter project: The project to toggle
    func toggleFavorite(_ project: Project) {
        project.isFavorite.toggle()
        project.lastAccessed = Date() // Update last accessed when interacting
    }
    
    /// Open a project (updates last accessed time)
    /// - Parameter project: The project to open
    func openProject(_ project: Project) {
        project.lastAccessed = Date()
        selectedProject = project
    }
    
    /// Create a new project
    /// - Parameters:
    ///   - name: Project name
    ///   - path: Path on server
    ///   - serverId: Associated server ID
    ///   - language: Programming language
    /// - Returns: The created project
    func createProject(name: String, path: String, serverId: UUID, language: String?) -> Project {
        let project = Project(
            name: name,
            path: path,
            serverId: serverId,
            language: language
        )
        return project
    }
}