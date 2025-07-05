//
//  ProjectService.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-05.
//
//  Purpose: Handles project-related operations
//  - Create/delete projects on remote servers
//  - Discover projects (if needed in future)
//  - Single responsibility: project file operations
//

import Foundation
import SwiftUI

/// Service for project-related operations on remote servers
@MainActor
class ProjectService {
    // MARK: - Properties
    
    private let sshService: SSHService
    
    // MARK: - Initialization
    
    init(sshService: SSHService) {
        self.sshService = sshService
    }
    
    // MARK: - Methods
    
    /// Create a new project directory on the server
    /// - Parameters:
    ///   - name: Name of the project
    ///   - server: Server to create the project on
    func createProject(name: String, on server: Server) async throws {
        SSHLogger.log("Creating project '\(name)' on server \(server.name)", level: .info)
        
        // Get a direct connection to the server
        let session = try await sshService.connect(to: server)
        
        // Define the project path
        let projectPath = "/root/projects/\(name)"
        
        // Create the project directory
        let result = try await session.execute("mkdir -p '\(projectPath)'")
        
        // Check if directory was created successfully
        let checkResult = try await session.execute("test -d '\(projectPath)' && echo 'EXISTS'")
        guard checkResult.trimmingCharacters(in: .whitespacesAndNewlines) == "EXISTS" else {
            throw ProjectServiceError.failedToCreateDirectory
        }
        
        SSHLogger.log("Successfully created project at \(projectPath)", level: .info)
    }
    
    /// Delete a project directory from the server
    /// - Parameter project: Project to delete
    func deleteProject(_ project: RemoteProject) async throws {
        guard let server = ServerManager.shared.server(withId: project.serverId) else {
            throw ProjectServiceError.serverNotFound
        }
        
        SSHLogger.log("Deleting project '\(project.name)' from server \(server.name)", level: .info)
        
        // Get a connection for this project
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        
        // Confirm the directory exists before deletion
        let checkResult = try await session.execute("test -d '\(project.path)' && echo 'EXISTS'")
        guard checkResult.trimmingCharacters(in: .whitespacesAndNewlines) == "EXISTS" else {
            throw ProjectServiceError.projectNotFound
        }
        
        // Delete the project directory
        _ = try await session.execute("rm -rf '\(project.path)'")
        
        // Close all connections for this project
        sshService.closeConnections(projectId: project.id)
        
        SSHLogger.log("Successfully deleted project at \(project.path)", level: .info)
    }
}

// MARK: - Errors

enum ProjectServiceError: LocalizedError {
    case serverNotFound
    case projectNotFound
    case failedToCreateDirectory
    
    var errorDescription: String? {
        switch self {
        case .serverNotFound:
            return "Server not found"
        case .projectNotFound:
            return "Project directory not found on server"
        case .failedToCreateDirectory:
            return "Failed to create project directory"
        }
    }
}