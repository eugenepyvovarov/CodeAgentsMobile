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
        
        // Ensure the server has a default projects path
        if let swiftSHSession = session as? SwiftSHSession {
            try await swiftSHSession.ensureDefaultProjectsPath()
        }
        
        // Get the base path (fallback to /root/projects if not set)
        let basePath = server.defaultProjectsPath ?? "/root/projects"
        let projectPath = "\(basePath)/\(name)"
        
        SSHLogger.log("Creating project at path: \(projectPath)", level: .info)
        
        // First, ensure the base projects directory exists and check permissions
        _ = try await session.execute("mkdir -p '\(basePath)'")
        
        // Validate write permissions on the base directory
        let canWrite = try await validateWritePermission(at: basePath, using: session)
        
        if !canWrite {
            SSHLogger.log("No write permission at \(basePath), trying fallback", level: .warning)
            // If we can't write to the default location, try the fallback
            if basePath != "/root/projects" {
                let fallbackPath = "/root/projects/\(name)"
                _ = try await session.execute("mkdir -p '/root/projects'")
                
                if try await validateWritePermission(at: "/root/projects", using: session) {
                    SSHLogger.log("Using fallback path: \(fallbackPath)", level: .info)
                    _ = try await session.execute("mkdir -p '\(fallbackPath)'")
                    
                    // Verify creation
                    let checkFallback = try await session.execute("test -d '\(fallbackPath)' && echo 'EXISTS'")
                    guard checkFallback.trimmingCharacters(in: .whitespacesAndNewlines) == "EXISTS" else {
                        throw ProjectServiceError.failedToCreateDirectory
                    }
                    
                    SSHLogger.log("Successfully created project at fallback: \(fallbackPath)", level: .info)
                    return
                }
            }
            throw ProjectServiceError.noWritePermission
        }
        
        // Create the project directory
        _ = try await session.execute("mkdir -p '\(projectPath)'")
        
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
    
    // MARK: - Private Methods
    
    /// Validate write permissions at a given path
    /// - Parameters:
    ///   - path: Path to check
    ///   - session: SSH session to use for checking
    /// - Returns: true if writable, false otherwise
    private func validateWritePermission(at path: String, using session: SSHSession) async throws -> Bool {
        let result = try await session.execute("test -w '\(path)' && echo 'writable' || echo 'not writable'")
        return result.trimmingCharacters(in: .whitespacesAndNewlines) == "writable"
    }
}

// MARK: - Errors

enum ProjectServiceError: LocalizedError {
    case serverNotFound
    case projectNotFound
    case failedToCreateDirectory
    case noWritePermission
    
    var errorDescription: String? {
        switch self {
        case .serverNotFound:
            return "Server not found"
        case .projectNotFound:
            return "Project directory not found on server"
        case .failedToCreateDirectory:
            return "Failed to create project directory"
        case .noWritePermission:
            return "No write permission in the selected directory"
        }
    }
}