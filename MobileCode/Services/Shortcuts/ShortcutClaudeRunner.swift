//
//  ShortcutClaudeRunner.swift
//  CodeAgentsMobile
//
//  Created by Codex on 2025-07-06.
//

import Foundation
import SwiftData

enum ShortcutExecutionError: Error {
    case emptyPrompt
    case emptyResponse
    case timeout(seconds: Int)
    case claudeFailure(String)
}

/// Builds the effective prompt for a shortcut run.
enum ShortcutPromptBuilder {
    static func build(promptInput: String) -> String {
        promptInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Executes Claude runs for App Shortcuts.
@MainActor
final class ShortcutClaudeRunner {
    static let shared = ShortcutClaudeRunner()
    
    private let claudeService = ClaudeCodeService.shared
    private let projectContext = ProjectContext.shared
    private let serverManager = ServerManager.shared
    private let sshService = ServiceManager.shared.sshService
    
    private init() {}
    
    func run(
        metadata: ShortcutProjectMetadata,
        promptInput: String,
        timeout: TimeInterval,
        modelContext: ModelContext
    ) async throws -> String {
        let finalPrompt = ShortcutPromptBuilder.build(promptInput: promptInput)
        guard !finalPrompt.isEmpty else {
            throw ShortcutExecutionError.emptyPrompt
        }
        
        // Ensure ServerManager cache is hydrated from persistent storage if available
        if serverManager.servers.isEmpty {
            serverManager.loadServers(from: modelContext)
        }
        
        let project = try loadProject(from: metadata, modelContext: modelContext)
        _ = ensureServer(metadata: metadata, modelContext: modelContext)
        let previousProject = projectContext.activeProject
        projectContext.setActiveProject(project)

        if let mismatch = ClaudeProviderMismatchGuard.mismatch(for: project) {
            throw ShortcutExecutionError.claudeFailure(
                "Provider changed from \(mismatch.previous.displayName) to \(mismatch.current.displayName). Open the app and clear chat to continue, or switch back to \(mismatch.previous.displayName)."
            )
        }
        
        let chatViewModel = ChatViewModel()
        chatViewModel.configure(modelContext: modelContext, projectId: project.id)
        
        defer {
            chatViewModel.cleanup()
            project.activeStreamingMessageId = nil
            sshService.closeConnections(projectId: project.id)
            if let previousProject {
                projectContext.setActiveProject(previousProject)
            } else {
                projectContext.clearActiveProject()
            }
            save(modelContext)
        }
        
        do {
            try await runWithTimeout(seconds: timeout) {
                await chatViewModel.sendMessage(finalPrompt)
            }
        } catch let error as ShortcutExecutionError {
            if case .timeout = error,
               let fallback = latestAssistantText(from: chatViewModel),
               !fallback.isEmpty {
                return fallback
            }
            throw error
        }
        
        guard let responseText = latestAssistantText(from: chatViewModel),
              !responseText.isEmpty else {
            throw ShortcutExecutionError.emptyResponse
        }
        return responseText
    }
    
    private func ensureServer(metadata: ShortcutProjectMetadata, modelContext: ModelContext) -> Server {
        if let existing = serverManager.server(withId: metadata.serverId) {
            return existing
        }
        
        if let persisted = try? fetchServer(id: metadata.serverId, modelContext: modelContext) {
            var servers = serverManager.servers
            servers.append(persisted)
            serverManager.updateServers(servers)
            return persisted
        }
        
        let server = Server(
            name: metadata.serverName,
            host: metadata.serverHost,
            port: metadata.serverPort,
            username: metadata.serverUsername,
            authMethodType: metadata.authMethodType
        )
        server.id = metadata.serverId
        server.sshKeyId = metadata.sshKeyId
        
        var servers = serverManager.servers
        servers.removeAll { $0.id == server.id }
        servers.append(server)
        serverManager.updateServers(servers)
        
        return server
    }
    
    private func loadProject(from metadata: ShortcutProjectMetadata, modelContext: ModelContext) throws -> RemoteProject {
        if let existing = try fetchProject(id: metadata.id, modelContext: modelContext) {
            // Keep metadata fields in sync if necessary
            if existing.path != metadata.projectPath {
                existing.path = metadata.projectPath
            }
            return existing
        }
        
        // If agent is missing from persistent store, surface an explicit error
        throw ShortcutExecutionError.claudeFailure("Agent metadata is unavailable. Open the app to refresh shortcuts.")
    }
    
    private func fetchProject(id: UUID, modelContext: ModelContext) throws -> RemoteProject? {
        var descriptor = FetchDescriptor<RemoteProject>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
    
    private func fetchServer(id: UUID, modelContext: ModelContext) throws -> Server? {
        var descriptor = FetchDescriptor<Server>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
    
    private func save(_ modelContext: ModelContext) {
        do {
            try modelContext.save()
        } catch {
            print("⚠️ Failed to save shortcut persistence changes: \(error)")
        }
    }
    
    private func latestAssistantText(from viewModel: ChatViewModel) -> String? {
        guard let message = viewModel.messages.last(where: { $0.role == .assistant }) else {
            return nil
        }
        return message.displayText().trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func extractAssistantText(from metadata: [String: Any]) -> String? {
        guard let blocks = metadata["content"] as? [[String: Any]] else { return nil }
        
        let pieces = blocks.compactMap { block -> String? in
            guard let type = block["type"] as? String else { return nil }
            switch type {
            case "text":
                return block["text"] as? String
            case "tool_result":
                if let content = block["content"] as? [[String: Any]] {
                    let textSegments = content.compactMap { $0["text"] as? String }
                    let combined = textSegments.joined(separator: "\n")
                    return combined.isEmpty ? nil : combined
                }
                return nil
            default:
                return nil
            }
        }
        
        let combined = pieces.joined(separator: "\n\n")
        return combined.isEmpty ? nil : combined
    }
    
    private func extractErrorMessage(from chunk: MessageChunk, server: Server) -> String? {
        if !chunk.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return chunk.content
        }
        
        guard let metadata = chunk.metadata else {
            return nil
        }
        
        if let errorId = metadata["error"] as? String, errorId == "claude_not_installed" {
            return "Claude CLI is not installed on \(server.name). Install it with: npm install -g @anthropic-ai/claude-code"
        }
        
        if let type = metadata["type"] as? String {
            switch type {
            case "assistant":
                return extractAssistantText(from: metadata)
            case "result":
                if let result = metadata["result"] as? String {
                    return result
                }
            default:
                break
            }
        }
        
        return nil
    }
    
    private func runWithTimeout<T>(
        seconds: TimeInterval,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        let timeoutNanoseconds = UInt64((seconds * 1_000_000_000).rounded())
        let reportedSeconds = Int(ceil(seconds))
        
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw ShortcutExecutionError.timeout(seconds: reportedSeconds)
            }
            
            guard let result = try await group.next() else {
                throw ShortcutExecutionError.timeout(seconds: reportedSeconds)
            }
            
            group.cancelAll()
            return result
        }
    }
}
