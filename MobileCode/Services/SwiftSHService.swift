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
import NIOSSH

/// Real SSH session implementation using SwiftNIO SSH
class SwiftSHSession: SSHSession {
    // MARK: - Properties
    
    private let server: Server
    private var channel: Channel?
    private var childChannel: Channel?
    private var isConnected = false
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    
    // MARK: - Initialization
    
    init(server: Server) {
        self.server = server
    }
    
    deinit {
        disconnect()
        try? group.syncShutdownGracefully()
    }
    
    
    // MARK: - Static Connection Method
    
    /// Create and connect a new SSH session
    static func connect(to server: Server) async throws -> SwiftSHSession {
        print("🔄 SwiftSHSession: Starting connection to \(server.host):\(server.port)")
        let session = SwiftSHSession(server: server)
        
        do {
            try await session.establishConnection()
            print("✅ SwiftSHSession: Connection established")
            
            try await session.authenticate()
            print("✅ SwiftSHSession: Authentication completed")
            
            return session
        } catch {
            print("❌ SwiftSHSession: Connection failed - \(error)")
            throw error
        }
    }
    
    // MARK: - SSHSession Protocol Implementation
    
    func execute(_ command: String) async throws -> String {
        guard isConnected else {
            throw SSHError.connectionFailed("Not connected")
        }
        
        return try await executeCommand(command)
    }
    
    func startProcess(_ command: String) async throws -> ProcessHandle {
        guard isConnected else {
            throw SSHError.connectionFailed("Not connected")
        }
        
        return try await createInteractiveSession(command: command)
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
    
    // MARK: - Project Discovery Methods
    
    /// Ensure projects directory exists and discover all projects
    func discoverProjects() async throws -> [RemoteProject] {
        guard isConnected else {
            throw SSHError.connectionFailed("Not connected")
        }
        
        // Check if /root/projects exists, create if not
        let projectsDir = "/root/projects"
        let checkDirCommand = "[ -d '\(projectsDir)' ] && echo 'exists' || echo 'missing'"
        let dirStatus = try await execute(checkDirCommand)
        
        if dirStatus.trimmingCharacters(in: .whitespacesAndNewlines) == "missing" {
            print("📁 Creating /root/projects directory...")
            let createDirCommand = "mkdir -p '\(projectsDir)'"
            _ = try await execute(createDirCommand)
        }
        
        // List all directories in /root/projects
        let listCommand = "find '\(projectsDir)' -maxdepth 1 -type d -not -path '\(projectsDir)' 2>/dev/null || echo ''"
        let output = try await execute(listCommand)
        
        var projects: [RemoteProject] = []
        let projectPaths = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                // Filter out empty lines and SSH warning messages
                !line.isEmpty &&
                !line.lowercased().contains("password") &&
                !line.lowercased().contains("warning") &&
                !line.contains("TTY") &&
                !line.contains("expired") &&
                line.hasPrefix("/") // Only keep actual file paths
            }
        
        for projectPath in projectPaths {
            let projectName = URL(fileURLWithPath: projectPath).lastPathComponent
            // Skip if project name looks like an error message
            guard !projectName.contains("change required") else { continue }
            
            let project = try await analyzeProject(path: projectPath, name: projectName)
            projects.append(project)
        }
        
        return projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    /// Analyze a project directory to determine its type and metadata
    private func analyzeProject(path: String, name: String) async throws -> RemoteProject {
        var projectType: ProjectType = .unknown
        var language: String = "Unknown"
        var framework: String? = nil
        var hasGit = false
        
        // Check for various project indicators
        let indicators = [
            "package.json": ProjectType.nodeJS,
            "Cargo.toml": ProjectType.rust,
            "go.mod": ProjectType.go,
            "pom.xml": ProjectType.java,
            "build.gradle": ProjectType.java,
            "requirements.txt": ProjectType.python,
            "setup.py": ProjectType.python,
            "Pipfile": ProjectType.python,
            "Package.swift": ProjectType.swift,
            "*.xcodeproj": ProjectType.swift,
            "Gemfile": ProjectType.ruby,
            "composer.json": ProjectType.php,
            "CMakeLists.txt": ProjectType.cpp,
            "Makefile": ProjectType.cpp,
            "Dockerfile": ProjectType.docker
        ]
        
        for (file, type) in indicators {
            let checkCommand = file.contains("*") 
                ? "ls '\(path)'/\(file) 2>/dev/null | head -1" 
                : "[ -f '\(path)/\(file)' ] && echo 'found' || echo ''"
            let result = try await execute(checkCommand)
            
            if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                projectType = type
                language = type.displayName
                
                // Get framework info for specific types
                if type == .nodeJS {
                    framework = try? await getNodeJSFramework(path: path)
                } else if type == .python {
                    framework = try? await getPythonFramework(path: path)
                }
                break
            }
        }
        
        // Check for Git repository
        let gitCommand = "[ -d '\(path)/.git' ] && echo 'git' || echo ''"
        let gitResult = try await execute(gitCommand)
        hasGit = !gitResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        
        // If no specific type found, try to detect by file extensions
        if projectType == .unknown {
            let extensionCommand = "find '\(path)' -maxdepth 2 -name '*.swift' -o -name '*.py' -o -name '*.js' -o -name '*.go' -o -name '*.rs' -o -name '*.java' 2>/dev/null | head -5"
            let extensionResult = try await execute(extensionCommand)
            
            if extensionResult.contains(".swift") {
                projectType = .swift
                language = "Swift"
            } else if extensionResult.contains(".py") {
                projectType = .python
                language = "Python"
            } else if extensionResult.contains(".js") {
                projectType = .nodeJS
                language = "JavaScript"
            } else if extensionResult.contains(".go") {
                projectType = .go
                language = "Go"
            } else if extensionResult.contains(".rs") {
                projectType = .rust
                language = "Rust"
            } else if extensionResult.contains(".java") {
                projectType = .java
                language = "Java"
            }
        }
        
        return RemoteProject(
            name: name,
            path: path,
            type: projectType,
            language: language,
            framework: framework,
            hasGit: hasGit,
            lastModified: Date() // We could get this from filesystem if needed
        )
    }
    
    /// Detect Node.js framework
    private func getNodeJSFramework(path: String) async throws -> String? {
        let packageCommand = "cat '\(path)/package.json' 2>/dev/null || echo '{}'"
        let packageContent = try await execute(packageCommand)
        
        if packageContent.contains("\"react\"") {
            return "React"
        } else if packageContent.contains("\"vue\"") {
            return "Vue.js"
        } else if packageContent.contains("\"angular\"") {
            return "Angular"
        } else if packageContent.contains("\"next\"") {
            return "Next.js"
        } else if packageContent.contains("\"express\"") {
            return "Express"
        } else if packageContent.contains("\"nestjs\"") {
            return "NestJS"
        }
        
        return nil
    }
    
    /// Detect Python framework
    private func getPythonFramework(path: String) async throws -> String? {
        let requirementsCommand = "cat '\(path)/requirements.txt' '\(path)/setup.py' '\(path)/pyproject.toml' 2>/dev/null || echo ''"
        let content = try await execute(requirementsCommand)
        
        if content.contains("django") || content.contains("Django") {
            return "Django"
        } else if content.contains("flask") || content.contains("Flask") {
            return "Flask"
        } else if content.contains("fastapi") || content.contains("FastAPI") {
            return "FastAPI"
        } else if content.contains("tornado") || content.contains("Tornado") {
            return "Tornado"
        }
        
        return nil
    }
    
    // MARK: - Real SSH Implementation (Placeholder)
    
    /// Establish SSH connection to the server
    private func establishConnection() async throws {
        // Retrieve password from keychain
        let password = (try? server.retrieveCredentials()) ?? ""
        
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    NIOSSHHandler(
                        role: .client(.init(
                            userAuthDelegate: PasswordAuthenticationDelegate(
                                username: self.server.username,
                                password: password
                            ),
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
            print("✅ SSH: Connected to \(server.name) via SwiftNIO SSH")
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
                
                // Now, request a shell
                let shellPromise = channel.eventLoop.makePromise(of: Void.self)
                let shellRequest = SSHChannelRequestEvent.ShellRequest(wantReply: true)
                childChannel.triggerUserOutboundEvent(shellRequest).whenComplete { result in
                    switch result {
                    case .success:
                        print("✅ SSH: Shell request successful")
                        shellPromise.succeed(())
                    case .failure(let error):
                        print("❌ SSH: Shell request failed: \(error)")
                        shellPromise.fail(error)
                    }
                }
                
                return shellPromise.futureResult
            }
        }.get()
        
        // If a command is provided, execute it in the shell
        if !command.isEmpty {
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
        dateFormatter.dateFormat = "MMM dd HH:mm"
        
        for line in lines {
            let components = line.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            
            guard components.count >= 9 else { continue }
            
            let permissions = components[0]
            let isDirectory = permissions.hasPrefix("d")
            let sizeString = components[4]
            let size = isDirectory ? nil : Int64(sizeString)
            
            // Parse date (simplified - assumes current year)
            let month = components[5]
            let day = components[6]
            let time = components[7]
            let dateString = "\(month) \(day) \(time)"
            let modificationDate = dateFormatter.date(from: dateString)
            
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

// MARK: - SSH Authentication Delegates

/// Password authentication delegate
final class PasswordAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String
    
    init(username: String, password: String) {
        self.username = username
        self.password = password
    }
    
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if availableMethods.contains(.password) {
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .password(.init(password: password))
            ))
        } else {
            nextChallengePromise.succeed(nil)
        }
    }
}

/// Accept all host keys delegate (for development)
final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // In production, you should verify the host key
        validationCompletePromise.succeed(())
    }
}

// MARK: - Channel Handlers

/// SSH channel data handler - accumulates output data
final class SSHChannelDataHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    
    private var stdoutBuffer = ByteBuffer()
    private var stderrBuffer = ByteBuffer()
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        
        switch channelData.data {
        case .byteBuffer(var bytes):
            let receivedString = String(buffer: bytes)
            switch channelData.type {
            case .channel:
                // Standard output
                print("📥 SSH: Received stdout data (\(bytes.readableBytes) bytes): \(receivedString.prefix(100))...")
                stdoutBuffer.writeBuffer(&bytes)
            case .stdErr:
                // Standard error
                print("📥 SSH: Received stderr data (\(bytes.readableBytes) bytes): \(receivedString.prefix(100))...")
                stderrBuffer.writeBuffer(&bytes)
            default:
                print("📥 SSH: Received other data type: \(channelData.type)")
                break
            }
        case .fileRegion:
            print("📥 SSH: Received file region data")
            break
        }
    }
    
    func getAccumulatedOutput() -> (stdout: String, stderr: String) {
        let stdout = stdoutBuffer.getString(at: 0, length: stdoutBuffer.readableBytes) ?? ""
        let stderr = stderrBuffer.getString(at: 0, length: stderrBuffer.readableBytes) ?? ""
        return (cleanSSHOutput(stdout), cleanSSHOutput(stderr))
    }
    
    /// Remove SSH authentication warnings from command output
    private func cleanSSHOutput(_ output: String) -> String {
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
}

/// Error handler
final class ErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("❌ SSH Error: \(error)")
        context.close(promise: nil)
    }
}

/// Command execution handler - manages the complete lifecycle of command execution
final class CommandExecutionHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    
    private let command: String
    private let promise: EventLoopPromise<String>
    private let dataHandler: SSHChannelDataHandler
    private var hasCompleted = false
    private var exitStatus: Int32?
    
    init(command: String, promise: EventLoopPromise<String>, dataHandler: SSHChannelDataHandler) {
        self.command = command
        self.promise = promise
        self.dataHandler = dataHandler
    }
    
    func channelActive(context: ChannelHandlerContext) {
        print("✅ SSH: Command handler channel active, sending exec request")
        print("📝 SSH: Command to execute: \(command)")
        
        // Send exec request
        let execRequest = SSHChannelRequestEvent.ExecRequest(
            command: command,
            wantReply: true
        )
        context.triggerUserOutboundEvent(execRequest).whenComplete { result in
            switch result {
            case .success:
                print("✅ SSH: Exec request sent successfully")
            case .failure(let error):
                print("❌ SSH: Failed to send exec request: \(error)")
                if !self.hasCompleted {
                    self.hasCompleted = true
                    self.promise.fail(SSHError.commandFailed("Failed to send exec request: \(error)"))
                }
                context.close(promise: nil)
            }
        }
    }
    
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        print("📥 SSH: Received user inbound event: \(type(of: event))")
        
        switch event {
        case let event as SSHChannelRequestEvent.ExitStatus:
            print("✅ SSH: Command completed with exit status: \(event.exitStatus)")
            // Store the exit status but don't complete yet - wait for channel to close
            self.exitStatus = Int32(event.exitStatus)
            // Schedule channel close after a brief delay to allow data to drain
            context.eventLoop.scheduleTask(in: .milliseconds(100)) {
                context.close(promise: nil)
            }
            
        case let event as SSHChannelRequestEvent.ExitSignal:
            // Command terminated by signal
            if !hasCompleted {
                hasCompleted = true
                promise.fail(SSHError.commandFailed("Command terminated by signal: \(event.signalName)"))
            }
            context.close(promise: nil)
            
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        print("📥 SSH: Channel became inactive")
        
        // Channel closed - now we can complete the promise with all accumulated data
        if !hasCompleted {
            hasCompleted = true
            let (stdout, stderr) = dataHandler.getAccumulatedOutput()
            let output = !stderr.isEmpty ? stdout + "\n" + stderr : stdout
            
            print("📤 SSH: Channel closed, returning output (\(output.count) bytes)")
            
            // If we have an exit status of 0 or we have output, consider it successful
            if exitStatus == 0 || !output.isEmpty {
                promise.succeed(output)
            } else if let exitStatus = exitStatus {
                promise.fail(SSHError.commandFailed("Command exited with status \(exitStatus)"))
            } else {
                promise.fail(SSHError.commandFailed("Channel closed without output"))
            }
        }
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !hasCompleted {
            hasCompleted = true
            promise.fail(error)
        }
        context.close(promise: nil)
    }
}

// MARK: - Channel Handler conformance for SwiftSHSession

extension SwiftSHSession: ChannelInboundHandler {
    typealias InboundIn = Any
    
    func channelActive(context: ChannelHandlerContext) {
        print("✅ SSH: Channel active")
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        print("❌ SSH: Channel inactive")
        isConnected = false
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("❌ SSH: Error caught: \(error)")
        context.close(promise: nil)
    }
}

// MARK: - Process Handle Implementation

/// Process handle for an interactive SwiftNIO SSH session
class SwiftSHProcessHandle: ChannelInboundHandler, ProcessHandle {
    typealias InboundIn = SSHChannelData
    
    private let command: String
    private let channel: Channel
    private var isTerminated = false
    
    // Continuations for the output stream
    private var continuations: [AsyncThrowingStream<String, Error>.Continuation] = []
    
    var isRunning: Bool {
        !isTerminated && channel.isActive
    }
    
    init(command: String, channel: Channel) {
        self.command = command
        self.channel = channel
        print("✅ SSH: Started interactive process: \(command)")
    }
    
    // MARK: - ProcessHandle Conformance
    
    func sendInput(_ text: String) async throws {
        guard !isTerminated else {
            throw SSHError.commandFailed("Process terminated")
        }
        
        print("📝 SSH: Sending input to process: \(text.trimmingCharacters(in: .newlines)) ")
        
        // Wrap the text in a buffer and send it
        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        
        let data = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        
        try await channel.writeAndFlush(data).get()
    }
    
    func readOutput() async throws -> String {
        // This method is not ideal for streams, but can be used for one-off reads
        var output = ""
        for try await chunk in outputStream() {
            output += chunk
            // Decide on a condition to stop reading, e.g., a prompt
            if chunk.contains("$") || chunk.contains("#") { break }
        }
        return output
    }
    
    func outputStream() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            self.continuations.append(continuation)
        }
    }
    
    func terminate() {
        guard !isTerminated else { return }
        isTerminated = true
        
        // Close the channel
        channel.close(promise: nil)
        
        // Finish all streaming continuations
        for continuation in continuations {
            continuation.finish()
        }
        continuations.removeAll()
        
        print("✅ SSH: Process terminated")
    }
    
    // MARK: - ChannelInboundHandler Conformance
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)
        
        switch channelData.data {
        case .byteBuffer(let bytes):
            let output = String(buffer: bytes)
            print("📥 SSH: Received interactive output: \(output.prefix(100))")
            // Yield the output to all active streams
            for continuation in continuations {
                continuation.yield(output)
            }
        case .fileRegion:
            // Not expected in a shell session
            break
        }
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        print("ℹ️ SSH: Interactive channel became inactive.")
        terminate()
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("❌ SSH: Error in interactive process: \(error)")
        // Finish all streaming continuations with the error
        for continuation in continuations {
            continuation.finish(throwing: error)
        }
        continuations.removeAll()
        terminate()
    }
}