//
//  SSHChannelHandlers.swift
//  CodeAgentsMobile
//
//  Purpose: SSH channel handlers for SwiftNIO SSH
//  - Channel data handling
//  - Command execution
//  - Error handling
//  - Authentication delegates
//

import Foundation
import NIO
import NIOSSH

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
        SSHLogger.log("SSHChannelDataHandler channelRead called with data type: \(type(of: data))", level: .verbose)
        let channelData = unwrapInboundIn(data)
        
        switch channelData.data {
        case .byteBuffer(let bytes):
            // Get string representation without consuming the buffer
            let receivedString = bytes.getString(at: bytes.readerIndex, length: bytes.readableBytes) ?? ""
            switch channelData.type {
            case .channel:
                // Standard output
                SSHLogger.log("Received stdout data (\(bytes.readableBytes) bytes): \(receivedString.prefix(100))...", level: .debug)
                var mutableBytes = bytes
                stdoutBuffer.writeBuffer(&mutableBytes)
            case .stdErr:
                // Standard error
                SSHLogger.log("Received stderr data (\(bytes.readableBytes) bytes): \(receivedString.prefix(100))...", level: .debug)
                var mutableBytes = bytes
                stderrBuffer.writeBuffer(&mutableBytes)
            default:
                SSHLogger.log("Received other data type: \(channelData.type)", level: .debug)
                break
            }
            
            // Forward the original ByteBuffer to the next handler (both stdout and stderr)
            SSHLogger.log("Forwarding \(bytes.readableBytes) bytes to next handler", level: .verbose)
            context.fireChannelRead(NIOAny(bytes))
        case .fileRegion:
            SSHLogger.log("Received file region data", level: .debug)
            break
        }
    }
    
    func getAccumulatedOutput() -> (stdout: String, stderr: String) {
        let stdout = stdoutBuffer.getString(at: 0, length: stdoutBuffer.readableBytes) ?? ""
        let stderr = stderrBuffer.getString(at: 0, length: stderrBuffer.readableBytes) ?? ""
        return (cleanSSHOutput(stdout), cleanSSHOutput(stderr))
    }
}

/// Error handler
final class ErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        SSHLogger.log("Error caught: \(error)", level: .error)
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
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Forward data to next handler
        context.fireChannelRead(data)
    }
    
    func channelActive(context: ChannelHandlerContext) {
        SSHLogger.log("Command handler channel active, sending exec request", level: .info)
        SSHLogger.log("Command to execute: \(command)", level: .debug)
        
        // Send exec request
        let execRequest = SSHChannelRequestEvent.ExecRequest(
            command: command,
            wantReply: true
        )
        context.triggerUserOutboundEvent(execRequest).whenComplete { result in
            switch result {
            case .success:
                SSHLogger.log("Exec request sent successfully", level: .info)
            case .failure(let error):
                SSHLogger.log("Failed to send exec request: \(error)", level: .error)
                if !self.hasCompleted {
                    self.hasCompleted = true
                    self.promise.fail(SSHError.commandFailed("Failed to send exec request: \(error)"))
                }
                context.close(promise: nil)
            }
        }
    }
    
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        SSHLogger.log("Received user inbound event: \(type(of: event))", level: .verbose)
        
        switch event {
        case is ChannelSuccessEvent:
            SSHLogger.log("Channel success event received - command accepted", level: .info)
            // Don't close yet, wait for data
            
        case let event as SSHChannelRequestEvent.ExitStatus:
            SSHLogger.log("Command completed with exit status: \(event.exitStatus)", level: .info)
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
            SSHLogger.log("Unknown event type: \(event)", level: .verbose)
            context.fireUserInboundEventTriggered(event)
        }
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        SSHLogger.log("Channel became inactive", level: .debug)
        
        // Channel closed - now we can complete the promise with all accumulated data
        if !hasCompleted {
            hasCompleted = true
            let (stdout, stderr) = dataHandler.getAccumulatedOutput()
            let output = !stderr.isEmpty ? stdout + "\n" + stderr : stdout
            
            SSHLogger.log("Channel closed, returning output (\(output.count) bytes)", level: .debug)
            
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

// MARK: - Process Handle Implementation

/// Process handle for an interactive SwiftNIO SSH session
final class SwiftSHProcessHandle: ChannelInboundHandler, ProcessHandle, @unchecked Sendable {
    typealias InboundIn = Any
    
    private let command: String
    private let parentChannel: Channel
    private var childChannel: Channel?
    private var isTerminated = false
    private var hasReceivedFirstOutput = false
    private var commandEchoBuffer = ""
    
    // Continuations for the output stream
    private var continuations: [AsyncThrowingStream<String, Error>.Continuation] = []
    
    // Buffer for output that arrives before continuations are ready
    private var earlyOutputBuffer: [String] = []
    
    var isRunning: Bool {
        !isTerminated && (childChannel?.isActive ?? false)
    }
    
    init(command: String, channel: Channel) {
        self.command = command
        self.parentChannel = channel
        if !command.isEmpty {
            SSHLogger.log("Started process for command: \(command)", level: .info)
        } else {
            SSHLogger.log("Started interactive shell", level: .info)
        }
    }
    
    func setChildChannel(_ channel: Channel) {
        self.childChannel = channel
    }
    
    // MARK: - ProcessHandle Conformance
    
    func sendInput(_ text: String) async throws {
        guard !isTerminated else {
            throw SSHError.commandFailed("Process terminated")
        }
        
        guard let channel = childChannel else {
            throw SSHError.commandFailed("No active child channel")
        }
        
        SSHLogger.log("Sending input to process: \(text.trimmingCharacters(in: .newlines))", level: .debug)
        
        // Wrap the text in a buffer and send it
        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        
        // Wrap in SSHChannelData for the SSH channel
        let data = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        
        // Write the SSH channel data
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
            
            // Flush any buffered output to the new continuation
            if !earlyOutputBuffer.isEmpty {
                SSHLogger.log("Flushing \(earlyOutputBuffer.count) buffered chunks to new continuation", level: .debug)
                for bufferedOutput in earlyOutputBuffer {
                    continuation.yield(bufferedOutput)
                }
                earlyOutputBuffer.removeAll()
            }
        }
    }
    
    func terminate() {
        guard !isTerminated else { return }
        isTerminated = true
        
        // Close the child channel
        childChannel?.close(promise: nil)
        
        // Finish all streaming continuations
        for continuation in continuations {
            continuation.finish()
        }
        continuations.removeAll()
        
        SSHLogger.log("Process terminated", level: .info)
    }
    
    // MARK: - ChannelInboundHandler Conformance
    
    func channelActive(context: ChannelHandlerContext) {
        SSHLogger.log("Process handle channel active, channel isActive: \(context.channel.isActive)", level: .info)
        
        // Store the child channel reference immediately
        self.childChannel = context.channel
        
        // For direct exec, the exec request should be sent here
        if !command.isEmpty {
            SSHLogger.log("Sending exec request for command: \(command)", level: .debug)
            let execRequest = SSHChannelRequestEvent.ExecRequest(
                command: command,
                wantReply: true
            )
            
            // Send the exec request
            context.triggerUserOutboundEvent(execRequest).whenComplete { result in
                switch result {
                case .success:
                    SSHLogger.log("Exec request sent successfully from process handle", level: .info)
                    // CRITICAL: Flush the channel to ensure the exec request is sent immediately
                    context.flush()
                    // Reading will start when we receive ChannelSuccessEvent in userInboundEventTriggered
                case .failure(let error):
                    SSHLogger.log("Failed to send exec request: \(error)", level: .error)
                    self.terminate()
                    for continuation in self.continuations {
                        continuation.finish(throwing: error)
                    }
                }
            }
        } else {
            // For interactive sessions, start reading immediately
            context.channel.read()
        }
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let unwrappedData = self.unwrapInboundIn(data)
        
        SSHLogger.log("SwiftSHProcessHandle channelRead called with data type: \(type(of: unwrappedData))", level: .verbose)
        
        // Process the data regardless of type
        var outputText: String? = nil
        
        // Handle IOData (SwiftNIO's wrapper for ByteBuffer)
        if let ioData = unwrappedData as? IOData {
            SSHLogger.log("Received IOData", level: .verbose)
            switch ioData {
            case .byteBuffer(let buffer):
                outputText = String(buffer: buffer)
                SSHLogger.log("Extracted ByteBuffer from IOData (\(outputText?.count ?? 0) chars): \(outputText?.prefix(100) ?? "")...", level: .debug)
            case .fileRegion:
                SSHLogger.log("Received file region in IOData", level: .debug)
                return
            }
        }
        // For SSH exec channels, data comes as ByteBuffer directly (after SSHChannelDataHandler)
        else if let buffer = unwrappedData as? ByteBuffer {
            outputText = String(buffer: buffer)
            SSHLogger.log("Received ByteBuffer output (\(outputText?.count ?? 0) chars): \(outputText?.prefix(100) ?? "")...", level: .debug)
        }
        // Handle SSHChannelData if it comes through (before SSHChannelDataHandler)
        else if let channelData = unwrappedData as? SSHChannelData {
            SSHLogger.log("Received SSHChannelData, type: \(channelData.type)", level: .verbose)
            
            switch channelData.data {
            case .byteBuffer(let bytes):
                outputText = String(buffer: bytes)
                let isError = channelData.type == .stdErr
                SSHLogger.log("\(isError ? "Stderr" : "Stdout") output (\(outputText?.count ?? 0) chars): \(outputText?.prefix(100) ?? "")...", level: .debug)
            case .fileRegion:
                SSHLogger.log("Received file region data", level: .debug)
                return
            }
        } else {
            SSHLogger.log("Received unknown data type: \(type(of: unwrappedData))", level: .warning)
            return
        }
        
        // Process the output text if we have any
        if let output = outputText, !output.isEmpty {
            // Check if we have continuations ready
            if continuations.isEmpty {
                SSHLogger.log("No continuations ready, buffering output (\(output.count) chars)", level: .debug)
                earlyOutputBuffer.append(output)
            } else {
                SSHLogger.log("Yielding output chunk (\(output.count) chars) to \(continuations.count) continuations", level: .debug)
                for continuation in continuations {
                    continuation.yield(output)
                }
            }
        }
        
        // Continue reading more data
        context.channel.read()
    }
    
    func channelReadComplete(context: ChannelHandlerContext) {
        SSHLogger.log("Channel read complete, triggering another read", level: .verbose)
        // Ensure we continue reading
        context.channel.read()
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        SSHLogger.log("Interactive channel became inactive", level: .info)
        terminate()
    }
    
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        SSHLogger.log("Process handle received event: \(type(of: event))", level: .verbose)
        
        switch event {
        case is ChannelSuccessEvent:
            SSHLogger.log("Channel success - exec request accepted", level: .info)
            // Command accepted, now we wait for output
            // CRITICAL: Start continuous reading
            context.channel.read()
            // Set up continuous reading loop
            startContinuousReading(context: context)
            
            // For exec commands, close the output (stdin) side to signal EOF
            // This tells the command that no more input is coming
            if !command.isEmpty {
                SSHLogger.log("Closing output side (stdin) for exec command", level: .debug)
                context.channel.close(mode: .output, promise: nil)
            }
            
        case let exitStatus as SSHChannelRequestEvent.ExitStatus:
            SSHLogger.log("Command exited with status: \(exitStatus.exitStatus)", level: .info)
            // Don't terminate immediately - let any remaining output be processed
            
        case let exitSignal as SSHChannelRequestEvent.ExitSignal:
            SSHLogger.log("Command terminated by signal: \(exitSignal.signalName)", level: .warning)
            
        default:
            SSHLogger.log("Unknown event type: \(event)", level: .verbose)
            context.fireUserInboundEventTriggered(event)
        }
    }
    
    private func startContinuousReading(context: ChannelHandlerContext) {
        // Schedule repeated reads to ensure we get all data
        let readTask = context.eventLoop.scheduleRepeatedTask(initialDelay: .milliseconds(10), delay: .milliseconds(100)) { task in
            guard self.isRunning else {
                task.cancel()
                return
            }
            context.channel.read()
        }
        
        // Store the task handle (you might want to add a property for this)
        // For now, it will be cancelled when the channel becomes inactive
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        SSHLogger.log("Error in interactive process: \(error)", level: .error)
        // Finish all streaming continuations with the error
        for continuation in continuations {
            continuation.finish(throwing: error)
        }
        continuations.removeAll()
        terminate()
    }
}