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

/// Connection key for SSH connection pooling.
///
/// Pooled by **server + purpose** (not project) so multiple projects on the same host
/// reuse one multiplexed SSH session instead of opening a new TCP login each time.
struct ConnectionKey: Hashable, CustomStringConvertible {
    let serverId: UUID
    let purpose: ConnectionPurpose

    var description: String {
        "\(serverId)_\(purpose.rawValue)"
    }
}

/// SSH-related errors
enum SSHError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case authenticationFailed
    case hostKeyMismatch(host: String, expected: String, presented: String)
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
        case .hostKeyMismatch(let host, let expected, let presented):
            return "SSH host key changed for \(host). Expected \(expected), got \(presented). Remove the server and re-add it only if you trust this host."
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
    /// Execute a command with user's shell environment (default - loads .zshrc/.bashrc)
    func execute(_ command: String) async throws -> String
    
    /// Execute a command without shell (raw execution - no PATH or environment setup)
    func executeRaw(_ command: String) async throws -> String
    
    /// Start a long-running process with user's shell environment (default)
    func startProcess(_ command: String) async throws -> ProcessHandle
    
    /// Start a long-running process without shell (raw execution)
    func startProcessRaw(_ command: String) async throws -> ProcessHandle

    /// Open a direct TCP/IP stream over SSH
    func openDirectTCPIP(targetHost: String, targetPort: Int) async throws -> ProcessHandle
    
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
    
    /// Close the session (must tear down the TCP connection, not only local flags)
    func disconnect()

    /// Whether the underlying transport is still usable for new channels.
    var isAlive: Bool { get }
}

extension SSHSession {
    /// Default for fakes / legacy mocks that do not track transport state.
    var isAlive: Bool { true }
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

/// SSH Logger configuration.
///
/// Release builds default to `.warning` and never emit payload/command bodies.
/// Debug builds default to `.info`. Call sites must not log stdin/stdout/base64.
struct SSHLogger {
    #if DEBUG
    static var logLevel: SSHLogLevel = .info
    #else
    static var logLevel: SSHLogLevel = .warning
    #endif

    /// Metadata-only log. Never pass command bodies, file contents, or secrets.
    static func log(_ message: String, level: SSHLogLevel = .info, file: String = #file, function: String = #function, line: Int = #line) {
        guard level.rawValue <= logLevel.rawValue else { return }

        #if !DEBUG
        // Production: only warning/error reach the console.
        guard level.rawValue <= SSHLogLevel.warning.rawValue else { return }
        #endif

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
