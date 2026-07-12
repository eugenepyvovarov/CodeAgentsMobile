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
        _ = try await createAgentDirectory(
            folderName: name,
            parentPath: customPath,
            on: server,
            allowFallback: true,
            failIfExists: false
        )
    }

    /// Create an agent directory and return the path that was actually created.
    /// - Parameters:
    ///   - folderName: Single path component (sanitized)
    ///   - parentPath: Parent directory; when nil, uses server default projects path
    ///   - server: Target server
    ///   - allowFallback: When true and parent is not writable, may create under `/root/projects`
    ///     (legacy create-agent behavior). Duplicate Agent should pass `false`.
    ///   - failIfExists: When true, refuse if the target directory already exists
    /// - Returns: Absolute remote path of the new directory
    @discardableResult
    func createAgentDirectory(
        folderName: String,
        parentPath: String?,
        on server: Server,
        allowFallback: Bool = true,
        failIfExists: Bool = false
    ) async throws -> String {
        guard let safeName = SSHShellQuoting.sanitizedPathComponent(folderName) else {
            throw ProjectServiceError.invalidName
        }
        SSHLogger.log("Creating agent on server \(server.name)", level: .info)

        // Pooled server session — avoid a fresh SSH login per create.
        let session = try await sshService.getConnection(for: server, purpose: .fileOperations)

        let basePath: String
        if let parentPath, !parentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            basePath = parentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            if let swiftSHSession = session as? SwiftSHSession {
                try await swiftSHSession.ensureDefaultProjectsPath()
            }
            basePath = server.defaultProjectsPath ?? "/root/projects"
        }

        let projectPath = AgentDuplicationPath.join(parent: basePath, folderName: safeName)
        let qBase = SSHShellQuoting.quote(basePath)

        SSHLogger.log("Creating agent directory", level: .info)

        _ = try await session.execute("mkdir -p -- \(qBase)")

        let canWrite = try await validateWritePermission(at: basePath, using: session)
        if !canWrite {
            SSHLogger.log("No write permission at base path, trying fallback", level: .warning)
            if allowFallback, basePath != "/root/projects" {
                let fallbackPath = AgentDuplicationPath.join(parent: "/root/projects", folderName: safeName)
                let qFallbackRoot = SSHShellQuoting.quote("/root/projects")
                _ = try await session.execute("mkdir -p -- \(qFallbackRoot)")

                if try await validateWritePermission(at: "/root/projects", using: session) {
                    SSHLogger.log("Using fallback path", level: .info)
                    try await createLeafDirectory(at: fallbackPath, exclusive: failIfExists, using: session)
                    SSHLogger.log("Successfully created agent at fallback", level: .info)
                    return fallbackPath
                }
            }
            throw ProjectServiceError.noWritePermission
        }

        try await createLeafDirectory(at: projectPath, exclusive: failIfExists, using: session)

        SSHLogger.log("Successfully created agent directory", level: .info)
        return projectPath
    }

    /// Create the agent leaf directory.
    /// - When `exclusive` is true, uses plain `mkdir` (no `-p`) so concurrent creators cannot both claim the same path;
    ///   existing directory → `directoryAlreadyExists`. Parent must already exist.
    /// - When `exclusive` is false, uses `mkdir -p` (legacy create-agent behavior).
    private func createLeafDirectory(
        at projectPath: String,
        exclusive: Bool,
        using session: SSHSession
    ) async throws {
        let qProject = SSHShellQuoting.quote(projectPath)
        if exclusive {
            // Atomic create of the leaf: only one concurrent caller wins; EEXIST → collision.
            let script = [
                "if mkdir -- \(qProject) 2>/dev/null; then",
                "echo CREATED;",
                "elif [ -d \(qProject) ]; then",
                "echo EXISTS;",
                "else",
                "echo FAILED;",
                "fi",
            ].joined(separator: " ")
            let result = try await session.execute(script)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch result {
            case "CREATED":
                return
            case "EXISTS":
                throw ProjectServiceError.directoryAlreadyExists
            default:
                throw ProjectServiceError.failedToCreateDirectory
            }
        }

        _ = try await session.execute("mkdir -p -- \(qProject)")
        let checkResult = try await session.execute("test -d \(qProject) && echo 'EXISTS'")
        guard checkResult.trimmingCharacters(in: .whitespacesAndNewlines) == "EXISTS" else {
            throw ProjectServiceError.failedToCreateDirectory
        }
    }

    /// Best-effort remove of a remote agent directory (used when local insert fails after mkdir).
    func removeAgentDirectory(at path: String, on server: Server) async throws {
        let session = try await sshService.connect(to: server)
        defer { session.disconnect() }
        try await removeRemotePathIfPresent(path, using: session)
    }
    
    /// Delete an agent directory from the server.
    /// Idempotent: if the path is already gone, succeeds so local cleanup can proceed.
    /// Verifies the path is gone after `rm` so a partial failure cannot leave a folder that
    /// later blocks Duplicate/Create with “folder already exists”.
    /// - Parameter project: Agent to delete
    func deleteProject(_ project: RemoteProject) async throws {
        guard let server = ServerManager.shared.server(withId: project.serverId) else {
            throw ProjectServiceError.serverNotFound
        }

        let path = project.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path != "/", !path.contains("..") else {
            throw ProjectServiceError.invalidName
        }

        SSHLogger.log("Deleting agent directory on server \(server.name) path=\(path)", level: .info)

        // Drop pooled sessions first so nothing holds the tree open for file ops / OpenCode.
        sshService.closeConnections(projectId: project.id)

        // Server-scoped connection (not project retainer) — project path may vanish mid-call.
        let session = try await sshService.connect(to: server)
        defer { session.disconnect() }

        try await removeRemotePathIfPresent(path, using: session)

        SSHLogger.log("Successfully deleted agent directory", level: .info)
    }

    /// Remove a remote path when present; no-op if already missing. Throws if it remains after `rm`.
    func removeRemotePathIfPresent(_ path: String, using session: SSHSession) async throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/", !trimmed.contains("..") else {
            throw ProjectServiceError.invalidName
        }
        let qPath = SSHShellQuoting.quote(trimmed)

        let before = try await session.execute("if [ -e \(qPath) ]; then echo EXISTS; else echo GONE; fi")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if before == "GONE" {
            SSHLogger.log("Agent directory already absent; treating delete as success", level: .info)
            return
        }

        // Best-effort chmod so root-owned leftovers under the tree are less likely to block rm.
        _ = try? await session.execute("chmod -R u+w -- \(qPath) 2>/dev/null || true")
        _ = try await session.execute("rm -rf -- \(qPath)")

        let after = try await session.execute("if [ -e \(qPath) ]; then echo EXISTS; else echo GONE; fi")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard after == "GONE" else {
            SSHLogger.log("Agent directory still present after rm -rf: \(trimmed)", level: .error)
            throw ProjectServiceError.failedToDeleteDirectory
        }
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
    case failedToDeleteDirectory
    case noWritePermission
    case invalidName
    case directoryAlreadyExists

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
        case .failedToDeleteDirectory:
            return "Could not delete the agent folder on the server. Check permissions and try again."
        case .noWritePermission:
            return "No write permission in the selected directory"
        case .directoryAlreadyExists:
            return "A folder with this name already exists on the server."
        }
    }
}
