//
//  TerminalViewModel.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//
//  Purpose: Manages terminal emulator state
//  - Handles command execution and output
//  - Manages command history
//  - Will integrate with SSH for real terminal access
//

import SwiftUI
import Observation

/// Represents a line in the terminal output
struct TerminalLine: Identifiable {
    let id = UUID()
    var content: String
    let type: LineType
    
    enum LineType {
        case command
        case output
        case error
        case system
    }

    var color: Color {
        switch type {
        case .command: return .green
        case .output: return .primary
        case .error: return .red
        case .system: return .blue
        }
    }
}

/// ViewModel for terminal functionality
/// Integrates with SSH service for real terminal access
@MainActor
@Observable
class TerminalViewModel {
    // MARK: - Properties
    
    /// All terminal output lines
    var outputLines: [TerminalLine] = []
    
    /// Command history for up/down navigation
    var commandHistory: [String] = []
    
    /// Current working directory
    var currentDirectory: String = "~"
    
    /// Terminal prompt string
    var prompt: String {
        let dirName = currentDirectory.split(separator: "/").last ?? "~"
        return "\(dirName) $ "
    }
    
    /// Whether a command is currently executing
    var isExecuting = false
    
    /// SSH Service reference
    private let sshService = ServiceManager.shared.sshService
    
    /// Handle for the interactive shell process
    private var processHandle: ProcessHandle?
    private var outputTask: Task<Void, Never>?

    // MARK: - Initialization
    
    init() {
        setupWelcomeMessage()
    }
    
    // Add a cleanup method that can be called before the view disappears
    func cleanup() {
        outputTask?.cancel()
        processHandle?.terminate()
        processHandle = nil
        outputTask = nil
    }
    
    // MARK: - Methods
    
    /// Send a command to the interactive shell
    /// - Parameter command: The command to execute
    func execute(_ command: String) async {
        guard !command.isEmpty else { return }
        
        // Add command to output
        outputLines.append(TerminalLine(
            content: "\(prompt)\(command)",
            type: .command
        ))
        
        // Add to history
        commandHistory.append(command)
        
        // Send command to the process
        guard let processHandle = processHandle else {
            outputLines.append(TerminalLine(content: "Error: Not connected to a shell.", type: .error))
            return
        }
        
        do {
            // Append newline to execute the command
            try await processHandle.sendInput("\(command)\n")
        } catch {
            outputLines.append(TerminalLine(content: "Error sending command: \(error.localizedDescription)", type: .error))
        }
    }
    
    /// Clear terminal output
    func clear() {
        outputLines.removeAll()
    }
    
    /// Kill current process
    func killProcess() {
        processHandle?.terminate()
        processHandle = nil
        outputTask?.cancel()
        outputLines.append(TerminalLine(content: "Process terminated.", type: .system))
    }
    
    /// Initialize terminal for a connected server
    /// - Parameter server: The connected server
    func initializeForServer(_ server: Server) async {
        clear()
        
        outputLines = [
            TerminalLine(content: "Claude Code Terminal - iOS", type: .system),
            TerminalLine(content: "Connecting to: \(server.name) (\(server.host))...", type: .system)
        ]
        
        guard let serverId = ConnectionManager.shared.currentServerId else {
            outputLines.append(TerminalLine(content: "Error: No active server connection.", type: .error))
            return
        }
        
        do {
            // Start an interactive shell process
            self.processHandle = try await sshService.startInteractiveSession(on: serverId)
            outputLines.append(TerminalLine(content: "Shell started.", type: .system))
            
            // Start listening for output
            listenForOutput()
            
            // Set initial directory
            try await processHandle?.sendInput("pwd\n")
            
        } catch {
            outputLines.append(TerminalLine(content: "Error starting shell: \(error.localizedDescription)", type: .error))
        }
    }
    
    // MARK: - Private Methods
    
    /// Start a task to listen for output from the shell process
    private func listenForOutput() {
        guard let processHandle = processHandle else { return }
        
        outputTask = Task { [weak self] in
            do {
                for try await output in processHandle.outputStream() {
                    // Check if self still exists
                    guard let self = self else { break }
                    
                    // Update the UI on the main thread
                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        
                        // Sanitize and append output
                        let sanitizedOutput = output.replacingOccurrences(of: "\r", with: "")
                        if let lastLine = self.outputLines.last, lastLine.type == .output {
                            self.outputLines[self.outputLines.count - 1].content += sanitizedOutput
                        } else {
                            self.outputLines.append(TerminalLine(content: sanitizedOutput, type: .output))
                        }
                        
                        // Update current directory from prompt
                        if let last = self.outputLines.last?.content.split(separator: "\n").last, last.contains("$") || last.contains("#") {
                            self.currentDirectory = String(last.dropLast(2))
                        }
                    }
                }
            } catch {
                guard let self = self else { return }
                
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    if !self.isExecuting {
                        self.outputLines.append(TerminalLine(content: "Connection lost: \(error.localizedDescription)", type: .error))
                    }
                }
            }
        }
    }
    
    /// Setup welcome message
    private func setupWelcomeMessage() {
        outputLines = [
            TerminalLine(content: "Claude Code Terminal - iOS", type: .system),
            TerminalLine(content: "Select a project to begin", type: .system)
        ]
    }
}