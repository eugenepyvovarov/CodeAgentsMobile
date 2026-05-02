//
//  CodingAgentMCPService.swift
//  CodeAgentsMobile
//
//  Purpose: Runtime-aware MCP management facade
//

import Foundation

@MainActor
final class CodingAgentMCPService: ObservableObject {
    static let shared = CodingAgentMCPService()

    private let claudeService: MCPService
    private let openCodeService: OpenCodeMCPService
    private let schedulerProvisionService: MCPTaskSchedulerProvisionService
    private let runtimeSelectionStore: CodingAgentRuntimeSelectionStore

    init(
        claudeService: MCPService? = nil,
        openCodeService: OpenCodeMCPService? = nil,
        schedulerProvisionService: MCPTaskSchedulerProvisionService? = nil,
        runtimeSelectionStore: CodingAgentRuntimeSelectionStore = CodingAgentRuntimeSelectionStore()
    ) {
        self.claudeService = claudeService ?? .shared
        self.openCodeService = openCodeService ?? .shared
        self.schedulerProvisionService = schedulerProvisionService ?? .shared
        self.runtimeSelectionStore = runtimeSelectionStore
    }

    func fetchServers(for project: RemoteProject, scope: MCPServer.MCPScope? = nil) async throws -> [MCPServer] {
        switch runtimeKind(for: project) {
        case .claudeProxy:
            return try await claudeService.fetchServers(for: project, scope: scope)
        case .openCode:
            return try await openCodeService.fetchServers(for: project, scope: scope)
        }
    }

    func addServer(
        _ server: MCPServer,
        scope: MCPServer.MCPScope = .project,
        for project: RemoteProject,
        allowManaged: Bool = false
    ) async throws {
        switch runtimeKind(for: project) {
        case .claudeProxy:
            try await claudeService.addServer(server, scope: scope, for: project, allowManaged: allowManaged)
        case .openCode:
            try await openCodeService.addServer(server, scope: scope, for: project, allowManaged: allowManaged)
        }
    }

    func removeServer(
        named name: String,
        scope: MCPServer.MCPScope? = nil,
        for project: RemoteProject,
        allowManaged: Bool = false
    ) async throws {
        switch runtimeKind(for: project) {
        case .claudeProxy:
            try await claudeService.removeServer(named: name, scope: scope, for: project, allowManaged: allowManaged)
        case .openCode:
            try await openCodeService.removeServer(named: name, scope: scope, for: project, allowManaged: allowManaged)
        }
    }

    func editServer(
        oldName: String,
        newServer: MCPServer,
        scope: MCPServer.MCPScope = .project,
        for project: RemoteProject,
        allowManaged: Bool = false
    ) async throws {
        switch runtimeKind(for: project) {
        case .claudeProxy:
            try await claudeService.editServer(
                oldName: oldName,
                newServer: newServer,
                scope: scope,
                for: project,
                allowManaged: allowManaged
            )
        case .openCode:
            try await openCodeService.editServer(
                oldName: oldName,
                newServer: newServer,
                scope: scope,
                for: project,
                allowManaged: allowManaged
            )
        }
    }

    func getServer(named name: String, for project: RemoteProject) async throws -> MCPServer? {
        switch runtimeKind(for: project) {
        case .claudeProxy:
            return try await claudeService.getServer(named: name, for: project)
        case .openCode:
            return try await openCodeService.getServer(named: name, for: project)
        }
    }

    func getServerDetails(
        named name: String,
        scope: MCPServer.MCPScope? = nil,
        for project: RemoteProject
    ) async throws -> (server: MCPServer, scope: MCPServer.MCPScope)? {
        switch runtimeKind(for: project) {
        case .claudeProxy:
            return try await claudeService.getServerDetails(named: name, scope: scope, for: project)
        case .openCode:
            return try await openCodeService.getServerDetails(named: name, scope: scope, for: project)
        }
    }

    func ensureManagedSchedulerServerIfNeeded(for project: RemoteProject) async throws {
        switch runtimeKind(for: project) {
        case .claudeProxy:
            try await schedulerProvisionService.ensureManagedSchedulerServer(for: project)
        case .openCode:
            guard await isDaemonHealthy(for: project) else {
                SSHLogger.log("Skipping OpenCode scheduler MCP provisioning: CodeAgents daemon is not healthy", level: .warning)
                return
            }
            try await openCodeService.addServer(
                schedulerProvisionService.managedSchedulerServer(for: project),
                scope: .project,
                for: project,
                allowManaged: true
            )
        }
    }

    func configurationPreview(
        for server: MCPServer,
        scope: MCPServer.MCPScope,
        in project: RemoteProject
    ) -> String {
        switch runtimeKind(for: project) {
        case .claudeProxy:
            return server.generateAddJsonCommand(scope: scope) ?? "Invalid configuration"
        case .openCode:
            return openCodeService.configurationPreview(for: server, scope: scope)
        }
    }

    func runtimeKind(for project: RemoteProject) -> CodingAgentRuntimeKind {
        CodingAgentRuntimeResolver.runtimeKind(for: project, selectionStore: runtimeSelectionStore)
    }

    private func isDaemonHealthy(for project: RemoteProject) async -> Bool {
        do {
            let session = try await ServiceManager.shared.sshService.getConnection(for: project, purpose: .agentDaemon)
            _ = try await session.execute(CodeAgentsDaemonProvisioning.healthCheckCommand())
            return true
        } catch {
            SSHLogger.log("CodeAgents daemon health check failed: \(error.localizedDescription)", level: .warning)
            return false
        }
    }
}
