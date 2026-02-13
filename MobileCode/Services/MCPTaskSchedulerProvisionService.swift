//
//  MCPTaskSchedulerProvisionService.swift
//  CodeAgentsMobile
//
//  Purpose: Ensures the managed scheduler MCP server is present for each active project.
//

import Foundation

@MainActor
final class MCPTaskSchedulerProvisionService {
    static let shared = MCPTaskSchedulerProvisionService()
    
    private let sshService = ServiceManager.shared.sshService
    
    private init() {}
    
    func ensureManagedSchedulerServer(for project: RemoteProject) async throws {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        let configPath = "\(project.path)/.mcp.json"
        let expectedServer = managedSchedulerServerConfiguration()
        
        var root = try await loadProjectMCPRoot(from: session, at: configPath)
        var mcpServers = root["mcpServers"] as? [String: Any] ?? [:]
        
        if let existing = mcpServers[MCPServer.managedSchedulerServerName] as? [String: Any],
           dictionariesEqual(existing, expectedServer) {
            return
        }
        
        mcpServers[MCPServer.managedSchedulerServerName] = expectedServer
        root["mcpServers"] = mcpServers
        
        try await writeProjectMCPRoot(root, to: session, at: configPath)
    }
    
    private func managedSchedulerServerConfiguration() -> [String: Any] {
        var config: [String: Any] = [
            "type": "http",
            "url": MCPServer.managedSchedulerServer.url ?? ""
        ]
        
        if let headers = MCPServer.managedSchedulerServer.headers, !headers.isEmpty {
            config["headers"] = headers
        }
        
        return config
    }
    
    private func loadProjectMCPRoot(
        from session: SSHSession,
        at path: String
    ) async throws -> [String: Any] {
        do {
            let contents = try await session.readFile(path)
            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return [:]
            }
            
            guard let data = trimmed.data(using: .utf8) else {
                throw MCPServiceError.invalidConfiguration("Unable to decode .mcp.json")
            }
            
            let parsed = try JSONSerialization.jsonObject(with: data, options: [])
            guard let root = parsed as? [String: Any] else {
                throw MCPServiceError.invalidConfiguration(".mcp.json root must be an object")
            }
            
            return root
        } catch {
            let errorMessage = error.localizedDescription.lowercased()
            if errorMessage.contains("no such file") ||
               errorMessage.contains("cannot open") {
                return [:]
            }
            throw error
        }
    }
    
    private func writeProjectMCPRoot(
        _ root: [String: Any],
        to session: SSHSession,
        at path: String
    ) async throws {
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let base64 = data.base64EncodedString()
        let escapedPath = escapeForDoubleQuotes(path)
        let command = "printf '%s' '\(base64)' | base64 -d > \"\(escapedPath)\""
        
        _ = try await session.execute(command)
    }
    
    private func escapeForDoubleQuotes(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
    
    private func dictionariesEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        guard
            let lhsData = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
            let rhsData = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys])
        else {
            return false
        }
        return lhsData == rhsData
    }
}
