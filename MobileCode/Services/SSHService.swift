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
    // MARK: - Singleton
    static let shared = SSHService()
    
    // MARK: - Properties
    
    /// Active SSH sessions keyed by ConnectionKey
    private var connectionPool: [ConnectionKey: SSHSession] = [:]
    
    /// Map to track which server each project belongs to
    private var projectServerMap: [UUID: UUID] = [:]
    
    // MARK: - Initialization
    private init() {}
    
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
    
    /// Authentication method for SSH connections
    enum AuthMethod {
        case password(String)
        case key(String) // Private key content
    }
    
    /// Connect to a server with explicit parameters (for cloud-init checking)
    /// - Parameters:
    ///   - host: Server hostname or IP
    ///   - port: SSH port
    ///   - username: SSH username
    ///   - authMethod: Authentication method (password or key)
    ///   - purpose: Purpose of the connection
    /// - Returns: Active SSH session (not pooled)
    func connectToServer(host: String, port: Int, username: String, authMethod: AuthMethod, purpose: ConnectionPurpose) async throws -> SSHSession {
        SSHLogger.log("Creating direct connection to \(host):\(port) for \(purpose)", level: .info)
        
        // Create a temporary server object for the connection
        let tempServer = Server(name: "temp-\(host)", host: host, port: port, username: username, authMethodType: "password")
        
        // Set up defer block to ensure cleanup happens
        defer {
            // Clean up temporary credentials
            switch authMethod {
            case .password:
                try? KeychainManager.shared.deletePassword(for: tempServer.id)
            case .key:
                if let keyId = tempServer.sshKeyId {
                    try? KeychainManager.shared.deleteSSHKey(for: keyId)
                }
            }
        }
        
        // Handle authentication based on method
        switch authMethod {
        case .password(let password):
            tempServer.authMethodType = "password"
            // Store password temporarily in keychain
            try KeychainManager.shared.storePassword(password, for: tempServer.id)
        case .key(let privateKey):
            tempServer.authMethodType = "key"
            // Create temporary SSH key ID and store the private key in keychain
            let tempKeyId = UUID()
            tempServer.sshKeyId = tempKeyId
            // Store the private key temporarily in keychain
            try KeychainManager.shared.storeSSHKey(Data(privateKey.utf8), for: tempKeyId)
        }
        
        let session = try await createSession(for: tempServer)
        
        return session
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
    
    /// Validate if an SSH connection is still alive
    /// - Parameter session: The SSH session to validate
    /// - Returns: True if connection is responsive
    func validateConnection(_ session: SSHSession) async -> Bool {
        // First check if session reports as connected
        guard session.isConnected else {
            SSHLogger.log("Session reports as disconnected", level: .debug)
            return false
        }
        
        do {
            // Send a simple echo command to test if the connection is actually responsive
            let result = try await session.execute("echo 'connection-test'")
            return !result.isEmpty && result.contains("connection-test")
        } catch {
            SSHLogger.log("Connection validation failed: \(error)", level: .debug)
            return false
        }
    }
    
    /// Get all active sessions for health monitoring
    /// - Returns: Array of active SSH sessions
    func getActiveSessions() -> [SSHSession] {
        return Array(connectionPool.values)
    }
    
    /// Clean up stale connections from the pool
    /// - Returns: Number of connections cleaned up
    func cleanupStaleConnections() async -> Int {
        var cleanedCount = 0
        
        for (key, session) in connectionPool {
            let isValid = await validateConnection(session)
            if !isValid {
                SSHLogger.log("Cleaning up stale connection for \(key)", level: .info)
                session.disconnect()
                connectionPool.removeValue(forKey: key)
                cleanedCount += 1
                
                // Also clean up project mapping if this was the last connection for the project
                if !connectionPool.keys.contains(where: { $0.projectId == key.projectId }) {
                    projectServerMap.removeValue(forKey: key.projectId)
                }
            }
        }
        
        if cleanedCount > 0 {
            SSHLogger.log("Cleaned up \(cleanedCount) stale connections", level: .info)
        }
        
        return cleanedCount
    }
    
    /// Reconnect all background-suspended connections
    /// - Returns: Number of connections reconnected
    func reconnectBackgroundConnections() async -> Int {
        var reconnectedCount = 0
        
        // Get all connections that need reconnection
        let staleConnections = connectionPool.filter { key, session in
            // For now, assume all connections need reconnection after backgrounding
            // In a more sophisticated implementation, we'd track background state
            return true
        }
        
        for (key, _) in staleConnections {
            do {
                // Get server for this connection
                let projectId = key.projectId
                guard let serverId = projectServerMap[projectId],
                      let server = ServerManager.shared.servers.first(where: { $0.id == serverId }) else {
                    continue
                }
                
                // Create new session
                let newSession = try await createSession(for: server)
                connectionPool[key] = newSession
                reconnectedCount += 1
                
                SSHLogger.log("Reconnected background connection for \(key)", level: .info)
            } catch {
                SSHLogger.log("Failed to reconnect for \(key): \(error)", level: .error)
            }
        }
        
        return reconnectedCount
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