//
//  SSHService.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//
//  Purpose: SSH connection management service
//  - Handles SSH connections to remote servers
//  - Executes commands and manages sessions
//  - File operations over SSH
//
//  Note: This is a protocol-based design. The actual implementation
//  will use NMSSH or SwiftSH library when added to the project.
//

import Foundation

/// Main SSH Service for managing connections
@MainActor
class SSHService {
    // MARK: - Properties
    
    /// Active SSH sessions keyed by ConnectionKey
    private var connectionPool: [ConnectionKey: SSHSession] = [:]
    
    /// Map to track which server each project belongs to
    private var projectServerMap: [UUID: UUID] = [:]
    
    // MARK: - Public Methods
    
    /// Connect directly to a server (for operations that don't require a project)
    /// - Parameters:
    ///   - server: Server to connect to  
    ///   - purpose: Purpose of the connection (defaults to fileOperations)
    /// - Returns: Active SSH session (not pooled)
    func connect(to server: Server, purpose: ConnectionPurpose = .fileOperations) async throws -> SSHSession {
        SSHLogger.log("Creating direct connection to server: \(server.name) for \(purpose)", level: .info)
        return try await createSession(for: server)
    }
    
    /// Get or create a connection for a specific project and purpose
    /// - Parameters:
    ///   - project: The project requiring the connection
    ///   - purpose: The purpose of the connection (claude, terminal, files)
    /// - Returns: Active SSH session
    func getConnection(for project: RemoteProject, purpose: ConnectionPurpose) async throws -> SSHSession {
        let key = ConnectionKey(projectId: project.id, purpose: purpose)
        
        // Check if connection exists and is active
        if let existingSession = connectionPool[key] {
            // Validate connection is still alive
            // For now, we assume it's valid - in production, add a health check
            SSHLogger.log("Reusing existing connection for \(key)", level: .debug)
            return existingSession
        }
        
        // Get server for this project
        let serverId = project.serverId
        guard let server = ServerManager.shared.servers.first(where: { $0.id == serverId }) else {
            throw SSHError.notConnected
        }
        
        // Create new connection
        SSHLogger.log("Creating new connection for \(key)", level: .info)
        let session = try await createSession(for: server)
        connectionPool[key] = session
        projectServerMap[project.id] = serverId
        
        return session
    }
    
    
    /// Check if a connection is active for a project and purpose
    /// - Parameters:
    ///   - projectId: Project ID to check
    ///   - purpose: Connection purpose
    /// - Returns: True if connection exists and is active
    func isConnectionActive(projectId: UUID, purpose: ConnectionPurpose) -> Bool {
        let key = ConnectionKey(projectId: projectId, purpose: purpose)
        return connectionPool[key] != nil
    }
    
    /// Get all active connection purposes for a project
    /// - Parameter projectId: Project ID to check
    /// - Returns: Array of active connection purposes
    func getActiveConnections(for projectId: UUID) -> [ConnectionPurpose] {
        var activePurposes: [ConnectionPurpose] = []
        
        for purpose in ConnectionPurpose.allCases {
            if isConnectionActive(projectId: projectId, purpose: purpose) {
                activePurposes.append(purpose)
            }
        }
        
        return activePurposes
    }
    
    /// Close connections for a project
    /// - Parameters:
    ///   - projectId: Project ID
    ///   - purpose: Optional specific purpose to close, nil closes all
    func closeConnections(projectId: UUID, purpose: ConnectionPurpose? = nil) {
        if let specificPurpose = purpose {
            // Close specific connection
            let key = ConnectionKey(projectId: projectId, purpose: specificPurpose)
            if let session = connectionPool[key] {
                SSHLogger.log("Closing connection for \(key)", level: .info)
                session.disconnect()
                connectionPool.removeValue(forKey: key)
            }
        } else {
            // Close all connections for this project
            for connectionPurpose in ConnectionPurpose.allCases {
                let key = ConnectionKey(projectId: projectId, purpose: connectionPurpose)
                if let session = connectionPool[key] {
                    SSHLogger.log("Closing connection for \(key)", level: .info)
                    session.disconnect()
                    connectionPool.removeValue(forKey: key)
                }
            }
            // Clean up project mapping
            projectServerMap.removeValue(forKey: projectId)
        }
    }
    
    /// Close all connections
    func closeAllConnections() {
        SSHLogger.log("Closing all \(connectionPool.count) connections", level: .info)
        for (key, session) in connectionPool {
            SSHLogger.log("Closing connection for \(key)", level: .debug)
            session.disconnect()
        }
        connectionPool.removeAll()
        projectServerMap.removeAll()
    }
    
    /// Disconnect a specific server connection (for non-project connections)
    /// - Parameter serverId: Server ID to disconnect
    func disconnect(from serverId: UUID) async {
        // Since direct connections aren't pooled, this is mainly for API consistency
        SSHLogger.log("Disconnect called for server \(serverId) - no action needed for direct connections", level: .debug)
    }
    
    // MARK: - Private Methods
    
    /// Create a new SSH session
    /// - Parameter server: Server configuration
    /// - Returns: New SSH session
    private func createSession(for server: Server) async throws -> SSHSession {
        SSHLogger.log("Creating SSH session for server: \(server.name)", level: .info)
        return try await SwiftSHSession.connect(to: server)
    }
    
    /// Get connection statistics
    var connectionStats: (total: Int, byPurpose: [ConnectionPurpose: Int]) {
        var purposeCount: [ConnectionPurpose: Int] = [:]
        for key in connectionPool.keys {
            purposeCount[key.purpose, default: 0] += 1
        }
        return (total: connectionPool.count, byPurpose: purposeCount)
    }
}