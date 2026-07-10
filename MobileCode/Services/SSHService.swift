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

@MainActor
protocol SSHConnectionProviding: AnyObject {
    func getConnection(for project: RemoteProject, purpose: ConnectionPurpose) async throws -> SSHSession
}

/// Main SSH Service for managing connections
@MainActor
class SSHService: SSHConnectionProviding {
    // MARK: - Singleton
    static let shared = SSHService()

    // MARK: - Properties

    /// Active SSH sessions keyed by server + purpose (shared across projects on that host).
    private var connectionPool: [ConnectionKey: SSHSession] = [:]

    /// Projects that currently retain each pooled connection.
    /// Session is closed only when the last retainer releases it (or it is dead/pruned).
    private var connectionRetainers: [ConnectionKey: Set<UUID>] = [:]

    /// In-flight SSH connection attempts keyed by ConnectionKey.
    ///
    /// Multiple view lifecycle tasks can ask for the same connection at the same time. Without coalescing, each
    /// caller passes the pool check before the first connection finishes, creating duplicate SSH sessions.
    private var connectionTasks: [ConnectionKey: Task<SSHSession, Error>] = [:]

    /// Map to track which server each project belongs to
    private var projectServerMap: [UUID: UUID] = [:]

    // MARK: - Initialization
    private init() {}

    // MARK: - Public Methods

    /// Connect directly to a server (for operations that don't require a project)
    /// - Parameters:
    ///   - server: Server to connect to
    ///   - purpose: Purpose of the connection (defaults to fileOperations)
    /// - Returns: Active SSH session (not pooled — caller must `disconnect()`)
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

    /// Get or create a connection for a specific project and purpose.
    /// Sessions are pooled per **server + purpose** so multiple agents on the same host share one login.
    func getConnection(for project: RemoteProject, purpose: ConnectionPurpose) async throws -> SSHSession {
        let serverId = project.serverId
        guard let server = ServerManager.shared.servers.first(where: { $0.id == serverId }) else {
            throw SSHError.notConnected
        }

        projectServerMap[project.id] = serverId
        return try await getOrCreatePooledConnection(
            server: server,
            purpose: purpose,
            retainerId: project.id
        )
    }

    /// Get or create a pooled connection for a server without a project context.
    ///
    /// Used by OpenCode health probes and connection warm-up so chat hydrate/send can reuse
    /// the same `.opencode` login instead of opening a second SSH session.
    /// Retains with `server.id` as a synthetic retainer until server-scope close or last release.
    func getConnection(for server: Server, purpose: ConnectionPurpose) async throws -> SSHSession {
        try await getOrCreatePooledConnection(
            server: server,
            purpose: purpose,
            retainerId: server.id
        )
    }

    /// Whether a pooled session for this server + purpose is currently alive.
    func hasLiveConnection(serverId: UUID, purpose: ConnectionPurpose) -> Bool {
        let key = ConnectionKey(serverId: serverId, purpose: purpose)
        pruneDeadConnection(for: key)
        return connectionPool[key]?.isAlive == true
    }

    /// Check if a connection is active for a project and purpose
    func isConnectionActive(projectId: UUID, purpose: ConnectionPurpose) -> Bool {
        guard let serverId = projectServerMap[projectId] else { return false }
        let key = ConnectionKey(serverId: serverId, purpose: purpose)
        guard let session = connectionPool[key], session.isAlive else { return false }
        return connectionRetainers[key]?.contains(projectId) == true
    }

    /// Get all active connection purposes for a project
    func getActiveConnections(for projectId: UUID) -> [ConnectionPurpose] {
        ConnectionPurpose.allCases.filter { isConnectionActive(projectId: projectId, purpose: $0) }
    }

    /// Close connections for a project.
    /// - Parameters:
    ///   - projectId: Project ID
    ///   - purpose: Optional specific purpose to close; nil closes all purposes for the project
    ///
    /// Only tears down the underlying SSH session when no other project still retains it.
    func closeConnections(projectId: UUID, purpose: ConnectionPurpose? = nil) {
        guard let serverId = projectServerMap[projectId] else {
            return
        }

        let purposes: [ConnectionPurpose]
        if let specificPurpose = purpose {
            purposes = [specificPurpose]
        } else {
            purposes = ConnectionPurpose.allCases
        }

        for connectionPurpose in purposes {
            let key = ConnectionKey(serverId: serverId, purpose: connectionPurpose)
            release(projectId: projectId, key: key)
        }

        if purpose == nil {
            projectServerMap.removeValue(forKey: projectId)
        }
    }

    /// Force-close every pooled session for a server (all purposes), ignoring retain counts.
    /// Use after auth changes or when the host is known to be unhealthy.
    func closeConnections(serverId: UUID, purpose: ConnectionPurpose? = nil) {
        let purposes: [ConnectionPurpose] = purpose.map { [$0] } ?? ConnectionPurpose.allCases
        for connectionPurpose in purposes {
            let key = ConnectionKey(serverId: serverId, purpose: connectionPurpose)
            forceClose(key: key, reason: "server-scope close")
        }
    }

    /// Drop any pooled sessions whose transport is no longer alive.
    @discardableResult
    func pruneDeadConnections() -> Int {
        var removed = 0
        for key in Array(connectionPool.keys) {
            if pruneDeadConnection(for: key) {
                removed += 1
            }
        }
        if removed > 0 {
            SSHLogger.log("Pruned \(removed) dead SSH connection(s)", level: .info)
        }
        return removed
    }

    /// Close all connections
    func closeAllConnections() {
        SSHLogger.log("Closing all \(connectionPool.count) connections", level: .info)
        for (key, session) in connectionPool {
            SSHLogger.log("Closing connection for \(key)", level: .debug)
            session.disconnect()
        }
        for task in connectionTasks.values {
            task.cancel()
        }
        connectionPool.removeAll()
        connectionTasks.removeAll()
        connectionRetainers.removeAll()
        projectServerMap.removeAll()
    }

    /// Disconnect a specific server connection (for non-project connections)
    func disconnect(from serverId: UUID) async {
        closeConnections(serverId: serverId)
    }

    // MARK: - Private Methods

    /// Shared pool entrypoint: one in-flight connect task per server+purpose so health probe,
    /// hydrate, and send never open concurrent logins for the same key.
    private func getOrCreatePooledConnection(
        server: Server,
        purpose: ConnectionPurpose,
        retainerId: UUID
    ) async throws -> SSHSession {
        let key = ConnectionKey(serverId: server.id, purpose: purpose)

        // Drop dead pooled sessions before reuse (stale after OOM / network blip).
        pruneDeadConnection(for: key)

        if let existingSession = connectionPool[key], existingSession.isAlive {
            retain(retainerId: retainerId, key: key)
            SSHLogger.log(
                "Reusing existing connection for \(key) (retainers=\(connectionRetainers[key]?.count ?? 0))",
                level: .debug
            )
            return existingSession
        }

        if let connectionTask = connectionTasks[key] {
            SSHLogger.log("Awaiting existing connection attempt for \(key)", level: .debug)
            let session = try await connectionTask.value
            // Task may have failed for another waiter, or session may have been pruned.
            if let pooled = connectionPool[key], pooled.isAlive {
                retain(retainerId: retainerId, key: key)
                return pooled
            }
            retain(retainerId: retainerId, key: key)
            return session
        }

        SSHLogger.log("Creating new connection for \(key)", level: .info)
        let connectionTask = Task { @MainActor in
            try await createSession(for: server)
        }
        connectionTasks[key] = connectionTask

        do {
            let session = try await connectionTask.value
            connectionPool[key] = session
            retain(retainerId: retainerId, key: key)
            connectionTasks.removeValue(forKey: key)
            return session
        } catch {
            connectionTasks.removeValue(forKey: key)
            throw error
        }
    }

    private func retain(retainerId: UUID, key: ConnectionKey) {
        var retainers = connectionRetainers[key] ?? []
        retainers.insert(retainerId)
        connectionRetainers[key] = retainers
    }

    private func release(projectId: UUID, key: ConnectionKey) {
        guard var retainers = connectionRetainers[key] else {
            // No retainers tracked — if a session exists only for this key, close it.
            if connectionPool[key] != nil {
                forceClose(key: key, reason: "release without retainers")
            }
            return
        }
        retainers.remove(projectId)
        if retainers.isEmpty {
            connectionRetainers.removeValue(forKey: key)
            forceClose(key: key, reason: "last retainer released")
        } else {
            connectionRetainers[key] = retainers
            SSHLogger.log(
                "Released \(key) for project \(projectId); \(retainers.count) retainer(s) remain",
                level: .debug
            )
        }
    }

    private func forceClose(key: ConnectionKey, reason: String) {
        if let session = connectionPool.removeValue(forKey: key) {
            SSHLogger.log("Closing connection for \(key) (\(reason))", level: .info)
            session.disconnect()
        }
        connectionTasks[key]?.cancel()
        connectionTasks.removeValue(forKey: key)
        connectionRetainers.removeValue(forKey: key)
    }

    @discardableResult
    private func pruneDeadConnection(for key: ConnectionKey) -> Bool {
        guard let session = connectionPool[key] else { return false }
        if session.isAlive { return false }
        SSHLogger.log("Pruning dead connection for \(key)", level: .warning)
        forceClose(key: key, reason: "dead transport")
        return true
    }

    private func createSession(for server: Server) async throws -> SSHSession {
        SSHLogger.log("Creating SSH session for server: \(server.name)", level: .info)
        // Opportunistically drop any other dead pooled sessions before opening a new login.
        _ = pruneDeadConnections()
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
