//
//  SwiftSHService.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//
//  Purpose: Real SSH implementation using SwiftNIO SSH
//  - Uses Apple's official SwiftNIO SSH library for real connections
//  - Supports password and key-based authentication
//  - Provides full SSH functionality on iOS
//

import Foundation
import NIO
@preconcurrency import NIOSSH

/// Real SSH session implementation using SwiftNIO SSH
class SwiftSHSession: SSHSession {
    // MARK: - Properties
    
    private let server: Server
    private var channel: Channel?
    private var childChannel: Channel?
    private var isConnected = false
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    
    // Cache the detected shell to avoid repeated detection
    private var detectedShell: String?
    
    // MARK: - Initialization
    
    init(server: Server) {
        self.server = server
        
        // Enable verbose logging for debugging
        SSHLogger.logLevel = .verbose
    }
    
    deinit {
        disconnect()
        // EventLoopGroup will be cleaned up automatically when deallocated
        // Calling syncShutdownGracefully() here can cause crashes if called from EventLoop thread
    }
    
    
    // MARK: - Static Connection Method
    
    /// Create and connect a new SSH session
    static func connect(to server: Server) async throws -> SwiftSHSession {
        SSHLogger.log("Starting connection to \(server.host):\(server.port)", level: .info)
        let session = SwiftSHSession(server: server)
        
        do {
            try await session.establishConnection()
            SSHLogger.log("Connection established", level: .info)
            
            try await session.authenticate()
            SSHLogger.log("Authentication completed", level: .info)
            
            return session
        } catch {
            SSHLogger.log("Connection failed - \(error)", level: .error)
            throw error
        }
    }
    
    // MARK: - SSHSession Protocol Implementation
    
    func executeRaw(_ command: String) async throws -> String {
        guard isConnected else {
            throw SSHError.connectionFailed("Not connected")
        }
        
        return try await executeCommand(command)
    }
    
    func execute(_ command: String) async throws -> String {
        guard isConnected else {
            throw SSHError.connectionFailed("Not connected")
        }
        
        // Detect shell if not already cached
        if detectedShell == nil {
            let detectShellCommand = "echo $SHELL"
            let userShell = try await executeCommand(detectShellCommand).trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Use the detected shell or fall back to bash if detection fails
            detectedShell = userShell.isEmpty || !userShell.hasPrefix("/") ? "/bin/bash" : userShell
            print("🐚 Detected user shell: \(detectedShell!)")
        }
        
        // Escape single quotes in the command to prevent shell injection
        let escapedCommand = command.replacingOccurrences(of: "'", with: "'\"'\"'")
        
        // Use login shell (-l) to ensure all profile files are loaded
        let shellWrapper = "\(detectedShell!) -l -c '\(escapedCommand)'"
        
        return try await executeCommand(shellWrapper)
    }
    
    func startProcessRaw(_ command: String) async throws -> ProcessHandle {
        guard isConnected else {
            throw SSHError.connectionFailed("Not connected")
        }
        
        // Use direct process for command execution (not interactive shell)
        return try await createDirectProcess(command: command)
    }
    
    func startProcess(_ command: String) async throws -> ProcessHandle {
        guard isConnected else {
            throw SSHError.connectionFailed("Not connected")
        }
        
        // Detect shell if not already cached
        if detectedShell == nil {
            let detectShellCommand = "echo $SHELL"
            let userShell = try await executeCommand(detectShellCommand).trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Use the detected shell or fall back to bash if detection fails
            detectedShell = userShell.isEmpty || !userShell.hasPrefix("/") ? "/bin/bash" : userShell
            print("🐚 Detected user shell: \(detectedShell!)")
        }
        
        // Escape single quotes in the command to prevent shell injection
        let escapedCommand = command.replacingOccurrences(of: "'", with: "'\"'\"'")
        
        // Use login shell (-l) to ensure all profile files are loaded
        let shellWrapper = "\(detectedShell!) -l -c '\(escapedCommand)'"
        
        return try await createDirectProcess(command: shellWrapper)
    }
    
    func uploadFile(localPath: URL, remotePath: String) async throws {
        guard isConnected else {
            throw SSHError.connectionFailed("Not connected")
        }
        
        // Read local file
        let data = try Data(contentsOf: localPath)
        let base64Content = data.base64EncodedString()
        
        // Use base64 encoding to transfer file
        let command = "echo '\(base64Content)' | base64 -d > '\(remotePath)'"
        _ = try await execute(command)
    }
    
    func downloadFile(remotePath: String, localPath: URL) async throws {
        guard isConnected else {
            throw SSHError.connectionFailed("Not connected")
        }
        
        // Use base64 encoding to transfer file
        let command = "base64 '\(remotePath)'"
        let base64Output = try await execute(command)
        
        // Decode and save
        guard let data = Data(base64Encoded: base64Output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw SSHError.fileTransferFailed("Failed to decode file content")
        }
        
        try data.write(to: localPath)
    }
    
    func readFile(_ remotePath: String) async throws -> String {
        guard isConnected else {
            throw SSHError.connectionFailed("Not connected")
        }
        
        // Read file content
        let command = "cat '\(remotePath)'"
        return try await execute(command)
    }
    
    func listDirectory(_ path: String) async throws -> [RemoteFile] {
        guard isConnected else {
            throw SSHError.connectionFailed("Not connected")
        }
        
        // Use ls command with specific format for parsing
        let command = "ls -la '\(path)' 2>/dev/null | tail -n +2"
        let output = try await execute(command)
        
        return parseDirectoryListing(output: output, basePath: path)
    }
    
    func disconnect() {
        isConnected = false
        // Clean up channels when SwiftNIO SSH is integrated
        childChannel = nil
        channel = nil
    }
    
    /// Explicit cleanup method for graceful shutdown
    /// Call this when you want to properly shutdown the EventLoopGroup
    /// This should NOT be called from an EventLoop thread
    func cleanup() async throws {
        disconnect()
        
        // Only attempt shutdown if we're not on an EventLoop thread
        if !group.any().inEventLoop {
            try await group.shutdownGracefully()
        }
    }
    
    // MARK: - Home Directory Detection
    
    /// Detect the user's home directory on the remote server
    func detectHomeDirectory() async throws -> String {
        guard isConnected else {
            throw SSHError.connectionFailed("Not connected")
        }
        
        let output = try await execute("echo $HOME")
        let homeDir = output.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Validate the output looks like a proper path
        guard !homeDir.isEmpty && homeDir.hasPrefix("/") else {
            SSHLogger.log("Invalid home directory detected: '\(homeDir)', falling back to /root", level: .warning)
            return "/root"
        }
        
        return homeDir
    }
    
    /// Ensure the server has a default projects path configured
    func ensureDefaultProjectsPath() async throws {
        // Skip if already configured
        guard server.defaultProjectsPath == nil else { return }
        
        let homeDir = try await detectHomeDirectory()
        server.defaultProjectsPath = "\(homeDir)/projects"
        
        SSHLogger.log("Set default projects path to: \(server.defaultProjectsPath ?? "unknown")", level: .info)
    }
    
    // MARK: - Real SSH Implementation
    
    /// Establish SSH connection to the server
    private func establishConnection() async throws {
        // Create the appropriate authentication delegate based on auth method
        let authDelegate: NIOSSHClientUserAuthenticationDelegate
        
        if server.authMethodType == "key", let sshKeyId = server.sshKeyId {
            // Use SSH key authentication
            SSHLogger.log("Using SSH key authentication for \(server.name)", level: .info)
            
            // Create a passphrase provider that could prompt the user if needed
            // For now, we'll use stored passphrase or nil
            authDelegate = PrivateKeyAuthenticationDelegate(
                username: server.username,
                keyId: sshKeyId
            ) { [weak self] in
                // In the future, this could prompt the user for passphrase
                // For now, return nil to use stored passphrase only
                return nil
            }
        } else {
            // Use password authentication
            SSHLogger.log("Using password authentication for \(server.name)", level: .info)
            
            // Retrieve password from keychain
            let password = (try? server.retrieveCredentials()) ?? ""
            
            authDelegate = PasswordAuthenticationDelegate(
                username: server.username,
                password: password
            )
        }
        
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    NIOSSHHandler(
                        role: .client(.init(
                            userAuthDelegate: authDelegate,
                            serverAuthDelegate: AcceptAllHostKeysDelegate()
                        )),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    ),
                    self
                ])
            }
        
        do {
            self.channel = try await bootstrap.connect(host: server.host, port: server.port).get()
            self.isConnected = true
            SSHLogger.log("Connected to \(server.name) via SwiftNIO SSH", level: .info)
        } catch {
            throw SSHError.connectionFailed("Failed to connect: \(error)")
        }
    }
    
    /// Perform SSH authentication
    private func authenticate() async throws {
        // Authentication is handled by the NIOSSHHandler during connection
        // This method is kept for compatibility
    }
    
    /// Execute a command over SSH
    private func executeCommand(_ command: String) async throws -> String {
        guard let channel = channel else {
            throw SSHError.connectionFailed("No active connection")
        }
        
        // Execute on the event loop to avoid threading issues
        return try await channel.eventLoop.flatSubmit {
            // Get the SSH handler from the pipeline
            return channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
                // Create a promise for the result
                let promise = channel.eventLoop.makePromise(of: String.self)
                let channelPromise = channel.eventLoop.makePromise(of: Channel.self)
                
                // Create child channel for command execution
                sshHandler.createChannel(channelPromise, channelType: .session) { childChannel, channelType in
                    // Enable half-closure for proper SSH channel handling
                    _ = childChannel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    
                    // Create data handler first so it can be shared
                    let dataHandler = SSHChannelDataHandler()
                    
                    // Add handlers in the correct order
                    return childChannel.pipeline.addHandlers([
                        dataHandler,
                        CommandExecutionHandler(
                            command: command,
                            promise: promise,
                            dataHandler: dataHandler
                        ),
                        ErrorHandler()
                    ])
                }
                
                // Set a timeout for command execution
                // Use longer timeout for Claude commands (10 minutes) vs regular commands (30 seconds)
                let timeoutSeconds: Int64 = command.contains("claude") ? 600 : 30
                let timeoutTask = channel.eventLoop.scheduleTask(in: .seconds(timeoutSeconds)) {
                    promise.fail(SSHError.commandFailed("Command timed out after \(timeoutSeconds) seconds"))
                }
                
                // Return a future that completes when command execution is done
                return channelPromise.futureResult.flatMap { childChannel in
                    self.childChannel = childChannel
                    return promise.futureResult.always { _ in
                        timeoutTask.cancel()
                    }
                }
            }
        }.get()
    }
    
    /// Create a direct process execution (non-interactive)
    private func createDirectProcess(command: String) async throws -> ProcessHandle {
        guard let channel = channel else {
            throw SSHError.connectionFailed("No active connection")
        }

        let processHandle = SwiftSHProcessHandle(command: command, channel: channel)
        
        // Execute on the event loop to avoid threading issues
        try await channel.eventLoop.flatSubmit {
            let promise = channel.eventLoop.makePromise(of: Channel.self)
            
            // Create child channel for the command
            channel.pipeline.handler(type: NIOSSHHandler.self).whenSuccess { sshHandler in
                sshHandler.createChannel(promise, channelType: .session) { childChannel, channelType in
                    // Enable half-closure for proper SSH channel handling
                    _ = childChannel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    // CRITICAL: Enable auto-read to ensure data flows
                    _ = childChannel.setOption(ChannelOptions.autoRead, value: true)
                    
                    // Create data handler to unwrap SSH channel data
                    let dataHandler = SSHChannelDataHandler()
                    
                    // Add handlers for the command execution
                    return childChannel.pipeline.addHandlers([
                        dataHandler,   // Unwraps SSH channel data
                        processHandle, // The process handle is also a channel handler
                        ErrorHandler()
                    ])
                }
            }
            
            // Wait for the child channel to be created
            return promise.futureResult.flatMap { childChannel in
                self.childChannel = childChannel
                // Set the child channel on the process handle
                processHandle.setChildChannel(childChannel)
                
                // The exec request will be sent by the process handle in channelActive
                // Read will be triggered after exec request is accepted
                return channel.eventLoop.makeSucceededFuture(())
            }
        }.get()
        
        return processHandle
    }
    
    /// Create an interactive SSH session
    private func createInteractiveSession(command: String) async throws -> ProcessHandle {
        guard let channel = channel else {
            throw SSHError.connectionFailed("No active connection")
        }

        let processHandle = SwiftSHProcessHandle(command: command, channel: channel)
        
        // Execute on the event loop to avoid threading issues
        try await channel.eventLoop.flatSubmit {
            let promise = channel.eventLoop.makePromise(of: Channel.self)
            
            // Create child channel for the shell
            channel.pipeline.handler(type: NIOSSHHandler.self).whenSuccess { sshHandler in
                sshHandler.createChannel(promise, channelType: .session) { childChannel, channelType in
                    // Enable half-closure for proper SSH channel handling
                    _ = childChannel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    // CRITICAL: Enable auto-read to ensure data flows
                    _ = childChannel.setOption(ChannelOptions.autoRead, value: true)
                    
                    // Add handlers for the interactive session
                    return childChannel.pipeline.addHandlers([
                        processHandle, // The process handle is also a channel handler
                        ErrorHandler()
                    ])
                }
            }
            
            // Wait for the child channel to be created
            return promise.futureResult.flatMap { childChannel in
                self.childChannel = childChannel
                // Set the child channel on the process handle
                processHandle.setChildChannel(childChannel)
                
                // Now, request a shell
                let shellPromise = channel.eventLoop.makePromise(of: Void.self)
                let shellRequest = SSHChannelRequestEvent.ShellRequest(wantReply: true)
                childChannel.triggerUserOutboundEvent(shellRequest).whenComplete { result in
                    switch result {
                    case .success:
                        SSHLogger.log("Shell request successful", level: .info)
                        shellPromise.succeed(())
                    case .failure(let error):
                        SSHLogger.log("Shell request failed: \(error)", level: .error)
                        shellPromise.fail(error)
                    }
                }
                
                return shellPromise.futureResult
            }
        }.get()
        
        // If a command is provided, send it to the shell
        if !command.isEmpty {
            // Small delay to ensure shell is ready
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            try await processHandle.sendInput("\(command)\n")
        }
        
        return processHandle
    }
    
    /// Parse directory listing output into RemoteFile objects
    private func parseDirectoryListing(output: String, basePath: String) -> [RemoteFile] {
        let lines = output.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        
        var files: [RemoteFile] = []
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        
        let currentYear = Calendar.current.component(.year, from: Date())
        
        for line in lines {
            let components = line.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            
            guard components.count >= 9 else { continue }
            
            let permissions = components[0]
            let isDirectory = permissions.hasPrefix("d")
            let sizeString = components[4]
            let size = isDirectory ? nil : Int64(sizeString)
            
            // Parse date - ls shows year for old files, time for recent files
            let month = components[5]
            let day = components[6]
            let timeOrYear = components[7]
            
            var modificationDate: Date?
            
            // Check if it's a year (4 digits) or time (HH:mm)
            if timeOrYear.contains(":") {
                // Recent file - shows time, assume current year
                dateFormatter.dateFormat = "MMM dd HH:mm yyyy"
                let dateString = "\(month) \(day) \(timeOrYear) \(currentYear)"
                modificationDate = dateFormatter.date(from: dateString)
                
                // If the date is in the future, it's probably from last year
                if let date = modificationDate, date > Date() {
                    dateFormatter.dateFormat = "MMM dd HH:mm yyyy"
                    let lastYearString = "\(month) \(day) \(timeOrYear) \(currentYear - 1)"
                    modificationDate = dateFormatter.date(from: lastYearString)
                }
            } else {
                // Older file - shows year instead of time
                dateFormatter.dateFormat = "MMM dd yyyy"
                let dateString = "\(month) \(day) \(timeOrYear)"
                modificationDate = dateFormatter.date(from: dateString)
            }
            
            // File name (rest of the components joined)
            let name = components[8...].joined(separator: " ")
            let fullPath = basePath.hasSuffix("/") ? "\(basePath)\(name)" : "\(basePath)/\(name)"
            
            let file = RemoteFile(
                name: name,
                path: fullPath,
                isDirectory: isDirectory,
                size: size,
                modificationDate: modificationDate,
                permissions: permissions
            )
            
            files.append(file)
        }
        
        return files.sorted { lhs, rhs in
            // Directories first, then files, both alphabetically
            if lhs.isDirectory && !rhs.isDirectory {
                return true
            } else if !lhs.isDirectory && rhs.isDirectory {
                return false
            } else {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }
    
}


// MARK: - Channel Handler conformance for SwiftSHSession

extension SwiftSHSession: ChannelInboundHandler {
    typealias InboundIn = Any
    
    func channelActive(context: ChannelHandlerContext) {
        SSHLogger.log("Channel active", level: .info)
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        SSHLogger.log("Channel inactive", level: .info)
        isConnected = false
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        SSHLogger.log("Error caught: \(error)", level: .error)
        context.close(promise: nil)
    }
}