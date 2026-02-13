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
    
    private let mcpService = MCPService.shared
    
    private init() {}
    
    func ensureManagedSchedulerServer(for project: RemoteProject) async throws {
        let expected = MCPServer.managedSchedulerServer
        let servers = try await mcpService.fetchServers(for: project)
        guard servers.contains(where: { $0.name == expected.name }) else {
            try await mcpService.addServer(expected, scope: .project, for: project, allowManaged: true)
            return
        }
        
        let details = try await mcpService.getServerDetails(
            named: expected.name,
            for: project
        )
        guard let (existingServer, scope) = details,
              existingServer.matchesManagedSchedulerDefinition() else {
            try await repairManagedServer(
                existingName: expected.name,
                expected: expected,
                project: project,
                scope: .project
            )
            return
        }
        
        if scope == .project {
            return
        }
        
        try await repairManagedServer(
            existingName: expected.name,
            expected: expected,
            project: project,
            scope: .project
        )
    }
    
    private func repairManagedServer(
        existingName: String,
        expected: MCPServer,
        project: RemoteProject,
        scope: MCPServer.MCPScope
    ) async throws {
        try await removeIfPresent(name: existingName, scope: nil, project: project)
        try await removeIfPresent(name: existingName, scope: .project, project: project)
        try await removeIfPresent(name: existingName, scope: .local, project: project)
        try await removeIfPresent(name: existingName, scope: .global, project: project)
        try await mcpService.addServer(expected, scope: scope, for: project, allowManaged: true)
    }
    
    private func removeIfPresent(
        name: String,
        scope: MCPServer.MCPScope?,
        project: RemoteProject
    ) async throws {
        do {
            try await mcpService.removeServer(named: name, scope: scope, for: project, allowManaged: true)
        } catch {
            if let errorMessage = error.localizedDescription.lowercased(),
               errorMessage.contains("not found") ||
               errorMessage.contains("no server named") {
                return
            }
            throw error
        }
    }
}
