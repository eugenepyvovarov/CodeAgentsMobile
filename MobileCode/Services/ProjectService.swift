//
//  ProjectService.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-05.
//
//  Purpose: Handles agent-related operations
//  - Create/delete agents on remote servers
//  - Discover agents (if needed in future)
//  - Single responsibility: agent file operations
//

import Foundation
import SwiftUI

/// Service for agent-related operations on remote servers
@MainActor
class ProjectService {
    // MARK: - Properties
    
    private let sshService: SSHService
    
    // MARK: - Initialization
    
    init(sshService: SSHService) {
        self.sshService = sshService
    }
    
    // MARK: - Methods
    
    /// Create a new agent directory on the server
    /// - Parameters:
    ///   - name: Name of the agent
    ///   - server: Server to create the agent on
    ///   - customPath: Optional custom path for the agent (if nil, uses server default)
    func createProject(name: String, on server: Server, customPath: String? = nil) async throws {
        guard let safeName = SSHShellQuoting.sanitizedPathComponent(name) else {
            throw ProjectServiceError.invalidName
        }
        SSHLogger.log("Creating agent on server \(server.name)", level: .info)

        // Get a direct connection to the server
        let session = try await sshService.connect(to: server)

        // Use custom path if provided, otherwise ensure the server has a default projects path
        let basePath: String
        if let customPath = customPath {
            basePath = customPath
        } else {
            if let swiftSHSession = session as? SwiftSHSession {
                try await swiftSHSession.ensureDefaultProjectsPath()
            }
            basePath = server.defaultProjectsPath ?? "/root/projects"
        }

        let projectPath = "\(basePath)/\(safeName)"
        let qBase = SSHShellQuoting.quote(basePath)
        let qProject = SSHShellQuoting.quote(projectPath)

        SSHLogger.log("Creating agent directory", level: .info)

        // First, ensure the base projects directory exists and check permissions
        _ = try await session.execute("mkdir -p -- \(qBase)")

        // Validate write permissions on the base directory
        let canWrite = try await validateWritePermission(at: basePath, using: session)

        if !canWrite {
            SSHLogger.log("No write permission at base path, trying fallback", level: .warning)
            // If we can't write to the default location, try the fallback
            if basePath != "/root/projects" {
                let fallbackPath = "/root/projects/\(safeName)"
                let qFallbackRoot = SSHShellQuoting.quote("/root/projects")
                let qFallback = SSHShellQuoting.quote(fallbackPath)
                _ = try await session.execute("mkdir -p -- \(qFallbackRoot)")

                if try await validateWritePermission(at: "/root/projects", using: session) {
                    SSHLogger.log("Using fallback path", level: .info)
                    _ = try await session.execute("mkdir -p -- \(qFallback)")

                    // Verify creation
                    let checkFallback = try await session.execute("test -d \(qFallback) && echo 'EXISTS'")
                    guard checkFallback.trimmingCharacters(in: .whitespacesAndNewlines) == "EXISTS" else {
                        throw ProjectServiceError.failedToCreateDirectory
                    }

                    SSHLogger.log("Successfully created agent at fallback", level: .info)
                    return
                }
            }
            throw ProjectServiceError.noWritePermission
        }

        // Create the project directory
        _ = try await session.execute("mkdir -p -- \(qProject)")

        // Check if directory was created successfully
        let checkResult = try await session.execute("test -d \(qProject) && echo 'EXISTS'")
        guard checkResult.trimmingCharacters(in: .whitespacesAndNewlines) == "EXISTS" else {
            throw ProjectServiceError.failedToCreateDirectory
        }

        SSHLogger.log("Successfully created agent directory", level: .info)
    }
    
    /// Delete an agent directory from the server
    /// - Parameter project: Agent to delete
    func deleteProject(_ project: RemoteProject) async throws {
        guard let server = ServerManager.shared.server(withId: project.serverId) else {
            throw ProjectServiceError.serverNotFound
        }
        
        SSHLogger.log("Deleting agent from server \(server.name)", level: .info)

        // Get a connection for this project
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        let qPath = SSHShellQuoting.quote(project.path)

        // Confirm the directory exists before deletion
        let checkResult = try await session.execute("test -d \(qPath) && echo 'EXISTS'")
        guard checkResult.trimmingCharacters(in: .whitespacesAndNewlines) == "EXISTS" else {
            throw ProjectServiceError.projectNotFound
        }

        // Delete the project directory (-- ends option parsing)
        _ = try await session.execute("rm -rf -- \(qPath)")

        // Close all connections for this project
        sshService.closeConnections(projectId: project.id)

        SSHLogger.log("Successfully deleted agent directory", level: .info)
    }

    // MARK: - Private Methods

    /// Validate write permissions at a given path
    /// - Parameters:
    ///   - path: Path to check
    ///   - session: SSH session to use for checking
    /// - Returns: true if writable, false otherwise
    private func validateWritePermission(at path: String, using session: SSHSession) async throws -> Bool {
        let qPath = SSHShellQuoting.quote(path)
        let result = try await session.execute("test -w \(qPath) && echo 'writable' || echo 'not writable'")
        return result.trimmingCharacters(in: .whitespacesAndNewlines) == "writable"
    }
}

// MARK: - Errors

enum ProjectServiceError: LocalizedError {
    case serverNotFound
    case projectNotFound
    case failedToCreateDirectory
    case noWritePermission
    case invalidName

    var errorDescription: String? {
        switch self {
        case .serverNotFound:
            return "Server not found"
        case .invalidName:
            return "Invalid agent name"
        case .projectNotFound:
            return "Agent directory not found on server"
        case .failedToCreateDirectory:
            return "Failed to create agent directory"
        case .noWritePermission:
            return "No write permission in the selected directory"
        }
    }
}
