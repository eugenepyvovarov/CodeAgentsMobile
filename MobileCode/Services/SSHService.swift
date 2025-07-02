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

/// SSH Session protocol - represents an active SSH connection
protocol SSHSession {
    /// Execute a command and return output
    func execute(_ command: String) async throws -> String
    
    /// Start a long-running process (like Claude Code CLI)
    func startProcess(_ command: String) async throws -> ProcessHandle
    
    /// Upload a file to the server
    func uploadFile(localPath: URL, remotePath: String) async throws
    
    /// Download a file from the server
    func downloadFile(remotePath: String, localPath: URL) async throws
    
    /// Read file content from remote
    /// - Parameter remotePath: Path on remote server
    /// - Returns: File content as string
    func readFile(_ remotePath: String) async throws -> String
    
    /// List files in a directory
    func listDirectory(_ path: String) async throws -> [RemoteFile]
    
    /// Discover projects on the server
    func discoverProjects() async throws -> [RemoteProject]
    
    /// Close the session
    func disconnect()
}

/// Handle for a running process
protocol ProcessHandle {
    /// Send input to the process
    func sendInput(_ text: String) async throws
    
    /// Read output from the process
    func readOutput() async throws -> String
    
    /// Read output as a stream
    func outputStream() -> AsyncThrowingStream<String, Error>
    
    /// Check if process is still running
    var isRunning: Bool { get }
    
    /// Kill the process
    func terminate()
}

/// Remote file information
struct RemoteFile {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64?
    let modificationDate: Date?
    let permissions: String?
}

/// Main SSH Service for managing connections
actor SSHService {
    // MARK: - Properties
    
    /// Active SSH sessions keyed by server ID
    private var sessions: [UUID: SSHSession] = [:]
    
    // MARK: - Public Methods
    
    /// Connect to a server
    /// - Parameter server: Server to connect to
    /// - Returns: Active SSH session
    func connect(to server: Server) async throws -> SSHSession {
        // Check if already connected
        if let existingSession = sessions[server.id] {
            return existingSession
        }
        
        // Create new session
        let session = try await createSession(for: server)
        sessions[server.id] = session
        
        return session
    }
    
    /// Disconnect from a server
    /// - Parameter serverId: ID of server to disconnect from
    func disconnect(from serverId: UUID) {
        if let session = sessions[serverId] {
            session.disconnect()
            sessions[serverId] = nil
        }
    }
    
    /// Check if connected to a server
    /// - Parameter serverId: Server ID to check
    /// - Returns: True if connected
    func isConnected(to serverId: UUID) -> Bool {
        return sessions[serverId] != nil
    }
    
    /// Execute a command on a server
    /// - Parameters:
    ///   - command: Command to execute
    ///   - serverId: Server to execute on
    /// - Returns: Command output
    func executeCommand(_ command: String, on serverId: UUID) async throws -> String {
        guard let session = sessions[serverId] else {
            throw SSHError.notConnected
        }
        
        return try await session.execute(command)
    }

    /// Start an interactive session on a server
    /// - Parameter serverId: Server to start session on
    /// - Returns: Process handle for the interactive session
    func startInteractiveSession(on serverId: UUID) async throws -> ProcessHandle {
        guard let session = sessions[serverId] else {
            throw SSHError.notConnected
        }
        
        // Start a shell process. The command can be empty for a default shell.
        return try await session.startProcess("")
    }
    
    // MARK: - Private Methods
    
    /// Create a new SSH session
    /// - Parameter server: Server configuration
    /// - Returns: New SSH session
    private func createSession(for server: Server) async throws -> SSHSession {
        print("🔄 SSHService: Creating SSH session for server: \(server.name)")
        return try await SwiftSHSession.connect(to: server)
    }
}

/// SSH-related errors
enum SSHError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case authenticationFailed
    case commandFailed(String)
    case fileTransferFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to server"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .authenticationFailed:
            return "Authentication failed"
        case .commandFailed(let reason):
            return "Command failed: \(reason)"
        case .fileTransferFailed(let reason):
            return "File transfer failed: \(reason)"
        }
    }
}