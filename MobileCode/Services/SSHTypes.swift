//
//  SSHTypes.swift
//  CodeAgentsMobile
//
//  Purpose: Common SSH-related types and protocols
//  - Shared types used across SSH services
//  - Error definitions
//  - Protocol definitions
//

import Foundation

/// Connection key for SSH connection pooling
struct ConnectionKey: Hashable, CustomStringConvertible {
    let projectId: UUID
    let purpose: ConnectionPurpose
    
    var description: String {
        "\(projectId)_\(purpose.rawValue)"
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

/// Remote file information
struct RemoteFile {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64?
    let modificationDate: Date?
    let permissions: String?
}

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

/// Logging levels for SSH operations
enum SSHLogLevel: Int {
    case none = 0
    case error = 1
    case warning = 2
    case info = 3
    case debug = 4
    case verbose = 5
}

/// SSH Logger configuration
struct SSHLogger {
    static var logLevel: SSHLogLevel = .info
    
    static func log(_ message: String, level: SSHLogLevel = .info, file: String = #file, function: String = #function, line: Int = #line) {
        guard level.rawValue <= logLevel.rawValue else { return }
        
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        let prefix: String
        
        switch level {
        case .none:
            return
        case .error:
            prefix = "❌"
        case .warning:
            prefix = "⚠️"
        case .info:
            prefix = "ℹ️"
        case .debug:
            prefix = "🔍"
        case .verbose:
            prefix = "📝"
        }
        
        print("\(prefix) SSH [\(fileName):\(line)] \(message)")
    }
}

/// Helper to clean SSH output
func cleanSSHOutput(_ output: String) -> String {
    let lines = output.components(separatedBy: .newlines)
    let cleanedLines = lines.filter { line in
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // Filter out common SSH warnings and authentication messages
        return !trimmed.isEmpty &&
               !trimmed.lowercased().contains("password change required") &&
               !trimmed.lowercased().contains("warning") &&
               !trimmed.contains("TTY") &&
               !trimmed.contains("expired") &&
               !trimmed.contains("Last login") &&
               !trimmed.contains("authenticity") &&
               !trimmed.contains("fingerprint")
    }
    return cleanedLines.joined(separator: "\n")
}