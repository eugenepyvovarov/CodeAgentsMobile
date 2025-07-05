//
//  ProjectsViewModel.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//
//  Purpose: Minimal project list operations
//  - Handles project opening
//  - Provides loading state for UI
//

import SwiftUI
import Observation

/// Minimal ViewModel for project list operations
@MainActor
@Observable
class ProjectsViewModel {
    // MARK: - Properties
    
    /// Loading state for UI feedback
    var isLoading = false
    
    // MARK: - Methods
    
    /// Open a project (can be extended to track analytics, etc.)
    /// - Parameter project: The project to open
    func openProject(_ project: RemoteProject) {
        // Currently just a placeholder
        // Can be extended to:
        // - Track usage analytics
        // - Update recent projects
        // - Prepare project resources
    }
}