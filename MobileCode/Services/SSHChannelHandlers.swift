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
        SSHLogger.log("channelRead called with data type: \(type(of: data))", level: .verbose)
        let channelData = unwrapInboundIn(data)
        
        switch channelData.data {
        case .byteBuffer(var bytes):
            let receivedString = String(buffer: bytes)
            switch channelData.type {
            case .channel:
                // Standard output
                SSHLogger.log("Received stdout data (\(bytes.readableBytes) bytes): \(receivedString.prefix(100))...", level: .debug)
                stdoutBuffer.writeBuffer(&bytes)
            case .stdErr:
                // Standard error
                SSHLogger.log("Received stderr data (\(bytes.readableBytes) bytes): \(receivedString.prefix(100))...", level: .debug)
                stderrBuffer.writeBuffer(&bytes)
            default:
                SSHLogger.log("Received other data type: \(channelData.type)", level: .debug)
                break
            }
        case .fileRegion:
            SSHLogger.log("Received file region data", level: .debug)
            break
        }
        
        // Forward the event
        context.fireChannelRead(data)
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
class SwiftSHProcessHandle: ChannelInboundHandler, ProcessHandle {
    typealias InboundIn = SSHChannelData
    
    private let command: String
    private let parentChannel: Channel
    private var childChannel: Channel?
    private var isTerminated = false
    private var hasReceivedFirstOutput = false
    private var commandEchoBuffer = ""
    
    // Continuations for the output stream
    private var continuations: [AsyncThrowingStream<String, Error>.Continuation] = []
    
    var isRunning: Bool {
        !isTerminated && (childChannel?.isActive ?? false)
    }
    
    init(command: String, channel: Channel) {
        self.command = command
        self.parentChannel = channel
        if !command.isEmpty {
            SSHLogger.log("Started interactive process: \(command)", level: .info)
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
        try await channel.writeAndFlush(NIOAny(data)).get()
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
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)
        
        SSHLogger.log("channelRead called, data type: \(channelData.type)", level: .verbose)
        
        // Process both stdout and stderr
        if channelData.type == .stdErr {
            // Handle stderr
            switch channelData.data {
            case .byteBuffer(let bytes):
                let error = String(buffer: bytes)
                SSHLogger.log("Stderr output: \(error)", level: .warning)
                // Also yield stderr to continuations as it might contain important info
                for continuation in continuations {
                    continuation.yield("❌ Error: \(error)")
                }
            case .fileRegion:
                break
            }
            return
        }
        
        // Only process channel data (stdout)
        guard channelData.type == .channel else {
            SSHLogger.log("Ignoring non-channel data type: \(channelData.type)", level: .verbose)
            return
        }
        
        switch channelData.data {
        case .byteBuffer(let bytes):
            let output = String(buffer: bytes)
            SSHLogger.log("Raw output received (\(output.count) chars): \(output.prefix(100))...", level: .verbose)
            
            // Simplified command echo filtering
            if !hasReceivedFirstOutput && !command.isEmpty {
                commandEchoBuffer += output
                
                // Look for the command followed by a newline
                if let range = commandEchoBuffer.range(of: "\(command)\n") {
                    hasReceivedFirstOutput = true
                    // Everything after the command+newline is the actual output
                    let actualOutput = String(commandEchoBuffer[range.upperBound...])
                    if !actualOutput.isEmpty {
                        SSHLogger.log("Received initial output (\(actualOutput.count) chars)", level: .debug)
                        for continuation in continuations {
                            continuation.yield(actualOutput)
                        }
                    }
                    commandEchoBuffer = ""
                } else if commandEchoBuffer.count > command.count + 1000 {
                    // Safety: if buffer is too large, just yield everything
                    hasReceivedFirstOutput = true
                    SSHLogger.log("No command echo detected, yielding all output", level: .debug)
                    for continuation in continuations {
                        continuation.yield(commandEchoBuffer)
                    }
                    commandEchoBuffer = ""
                }
            } else {
                // Normal output after command echo has been filtered
                SSHLogger.log("Received chunk (\(output.count) chars)", level: .debug)
                for continuation in continuations {
                    continuation.yield(output)
                }
            }
        case .fileRegion:
            // Not expected in a shell session
            break
        }
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        SSHLogger.log("Interactive channel became inactive", level: .info)
        terminate()
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