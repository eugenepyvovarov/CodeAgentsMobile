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
        let details = try await mcpService.getServerDetails(
            named: expected.name,
            scope: .project,
            for: project
        )
        
        if let details {
            let (existingServer, scope) = details
            let isExpectedDefinition = existingServer.matchesManagedSchedulerDefinition()
            let isProjectScope = scope == .project
            
            guard isProjectScope && isExpectedDefinition else {
                try await repairManagedServer(
                    existingName: existingServer.name,
                    expected: expected,
                    project: project,
                    scope: .project
                )
                return
            }
            
            return
        }
        
        try await mcpService.addServer(expected, scope: .project, for: project, allowManaged: true)
    }
    
    private func repairManagedServer(
        existingName: String,
        expected: MCPServer,
        project: RemoteProject,
        scope: MCPServer.MCPScope
    ) async throws {
        try await mcpService.removeServer(named: existingName, scope: scope, for: project, allowManaged: true)
        try await mcpService.addServer(expected, scope: scope, for: project, allowManaged: true)
    }
}
