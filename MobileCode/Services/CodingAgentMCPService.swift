//
//  CodingAgentMCPService.swift
//  CodeAgentsMobile
//
//  Purpose: Runtime-aware MCP management facade (OpenCode-primary after Claude migration)
//

import Foundation

@MainActor
final class CodingAgentMCPService: ObservableObject {
    static let shared = CodingAgentMCPService()

    private let openCodeService: OpenCodeMCPService
    private let schedulerProvisionService: MCPTaskSchedulerProvisionService
    private let avatarProvisionService: MCPAgentAvatarProvisionService
    private let runtimeSelectionStore: CodingAgentRuntimeSelectionStore
    private var schedulerProvisionTasks: [UUID: Task<Void, Error>] = [:]
    private var avatarProvisionTasks: [UUID: Task<Void, Error>] = [:]

    /// Retained for Claude CLI fallback during one-time Path D migration only.
    private let claudeService: MCPService

    init(
        claudeService: MCPService? = nil,
        openCodeService: OpenCodeMCPService? = nil,
        schedulerProvisionService: MCPTaskSchedulerProvisionService? = nil,
        avatarProvisionService: MCPAgentAvatarProvisionService? = nil,
        runtimeSelectionStore: CodingAgentRuntimeSelectionStore = CodingAgentRuntimeSelectionStore()
    ) {
        self.claudeService = claudeService ?? .shared
        self.openCodeService = openCodeService ?? .shared
        self.schedulerProvisionService = schedulerProvisionService ?? .shared
        self.avatarProvisionService = avatarProvisionService ?? .shared
        self.runtimeSelectionStore = runtimeSelectionStore
    }

    func fetchServers(for project: RemoteProject, scope: MCPServer.MCPScope? = nil) async throws -> [MCPServer] {
        try await openCodeService.fetchServers(for: project, scope: scope)
    }

    func addServer(
        _ server: MCPServer,
        scope: MCPServer.MCPScope = .project,
        for project: RemoteProject,
        allowManaged: Bool = false,
        enabled: Bool? = nil
    ) async throws {
        try await openCodeService.addServer(
            server,
            scope: scope,
            for: project,
            allowManaged: allowManaged,
            enabled: enabled
        )
    }

    /// Write a full project MCP configuration (preserves `oauth`, `timeout`, etc.).
    func addServerConfiguration(
        named name: String,
        configuration: OpenCodeMCPServerConfiguration,
        scope: MCPServer.MCPScope = .project,
        for project: RemoteProject,
        allowManaged: Bool = false
    ) async throws {
        try await openCodeService.addServerConfiguration(
            named: name,
            configuration: configuration,
            scope: scope,
            for: project,
            allowManaged: allowManaged
        )
    }

    func projectServerConfigurations(for project: RemoteProject) async throws -> [String: OpenCodeMCPServerConfiguration] {
        try await openCodeService.projectServerConfigurations(for: project)
    }

    /// Batch-write project MCP servers (one `opencode.json` write). See `OpenCodeMCPService`.
    func writeProjectServerConfigurations(
        _ configurations: [String: OpenCodeMCPServerConfiguration],
        for project: RemoteProject,
        activateLive: Bool = false
    ) async throws {
        try await openCodeService.writeProjectServerConfigurations(
            configurations,
            for: project,
            activateLive: activateLive
        )
    }

    /// OpenCode configuration for managed scheduler headers (clone-specific paths/ids).
    func managedSchedulerConfiguration(for project: RemoteProject) -> OpenCodeMCPServerConfiguration? {
        OpenCodeMCPServerConfiguration(
            server: schedulerProvisionService.managedSchedulerServer(for: project),
            enabled: true
        )
    }

    /// OpenCode configuration for managed avatar MCP (clone-specific script path).
    func managedAvatarConfiguration(for project: RemoteProject) -> OpenCodeMCPServerConfiguration {
        avatarProvisionService.managedAvatarServerConfiguration(for: project)
    }

    /// Upload avatar MCP script only (config is written via batch MCP).
    func deployManagedAvatarScript(for project: RemoteProject) async throws {
        try await avatarProvisionService.deployManagedAvatarScript(for: project)
    }

    func removeServer(
        named name: String,
        scope: MCPServer.MCPScope? = nil,
        for project: RemoteProject,
        allowManaged: Bool = false
    ) async throws {
        try await openCodeService.removeServer(named: name, scope: scope, for: project, allowManaged: allowManaged)
    }

    func editServer(
        oldName: String,
        newServer: MCPServer,
        scope: MCPServer.MCPScope = .project,
        for project: RemoteProject,
        allowManaged: Bool = false
    ) async throws {
        try await openCodeService.editServer(
            oldName: oldName,
            newServer: newServer,
            scope: scope,
            for: project,
            allowManaged: allowManaged
        )
    }

    func getServer(named name: String, for project: RemoteProject) async throws -> MCPServer? {
        try await openCodeService.getServer(named: name, for: project)
    }

    func getServerDetails(
        named name: String,
        scope: MCPServer.MCPScope? = nil,
        for project: RemoteProject
    ) async throws -> (server: MCPServer, scope: MCPServer.MCPScope)? {
        try await openCodeService.getServerDetails(named: name, scope: scope, for: project)
    }

    func ensureManagedSchedulerServerIfNeeded(for project: RemoteProject) async throws {
        if let existingTask = schedulerProvisionTasks[project.id] {
            try await existingTask.value
            return
        }

        let task = Task { @MainActor in
            try await ensureManagedSchedulerServer(for: project)
        }
        schedulerProvisionTasks[project.id] = task
        defer {
            schedulerProvisionTasks.removeValue(forKey: project.id)
        }
        try await task.value
    }

    func ensureManagedAvatarServerIfNeeded(for project: RemoteProject) async throws {
        if let existingTask = avatarProvisionTasks[project.id] {
            try await existingTask.value
            return
        }

        let task = Task { @MainActor in
            try await avatarProvisionService.ensureManagedAvatarServer(for: project)
        }
        avatarProvisionTasks[project.id] = task
        defer {
            avatarProvisionTasks.removeValue(forKey: project.id)
        }
        try await task.value
    }

    /// Path D: import Claude MCP definitions into OpenCode project config.
    /// Prefers `.mcp.json`; falls back to `claude mcp list` when the file is missing/empty.
    func migrateClaudeMCPToOpenCode(for project: RemoteProject) async throws -> MCPMigrationReport {
        do {
            let fileReport = try await openCodeService.importServersFromClaudeIfNeeded(for: project)
            if fileReport.note != "no_claude_mcp_source" || !fileReport.imported.isEmpty {
                return fileReport
            }
        } catch {
            SSHLogger.log(
                "OpenCode MCP file import failed, trying Claude CLI fallback: \(error.localizedDescription)",
                level: .warning
            )
        }

        // CLI fallback — best effort only (legacy Claude install).
        do {
            let claudeServers = try await claudeService.fetchServers(for: project, scope: .project)
                .map { $0.normalizedForOpenCodeImport() }
            if claudeServers.isEmpty {
                var report = MCPMigrationReport()
                report.note = "no_claude_mcp_source"
                return report
            }
            return try await openCodeService.importServersFromClaudeIfNeeded(
                for: project,
                claudeServersOverride: claudeServers
            )
        } catch {
            var report = MCPMigrationReport()
            report.note = "no_claude_mcp_source"
            SSHLogger.log(
                "Claude CLI MCP fallback unavailable during migration: \(error.localizedDescription)",
                level: .debug
            )
            return report
        }
    }

    private func ensureManagedSchedulerServer(for project: RemoteProject) async throws {
        // Always provision managed scheduler via OpenCode config after Claude chat retirement.
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

    func configurationPreview(
        for server: MCPServer,
        scope: MCPServer.MCPScope,
        in project: RemoteProject
    ) -> String {
        _ = project
        _ = scope
        return openCodeService.configurationPreview(for: server, scope: .project)
    }

    func runtimeKind(for project: RemoteProject) -> CodingAgentRuntimeKind {
        // Facade is OpenCode-primary; resolver still used for diagnostics/logging.
        let resolved = CodingAgentRuntimeResolver.runtimeKind(for: project, selectionStore: runtimeSelectionStore)
        return resolved == .openCode ? .openCode : .openCode
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
