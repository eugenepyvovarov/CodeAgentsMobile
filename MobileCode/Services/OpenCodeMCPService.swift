//
//  OpenCodeMCPService.swift
//  CodeAgentsMobile
//
//  Purpose: OpenCode-backed MCP server management
//

import Foundation

@MainActor
final class OpenCodeMCPService: ObservableObject {
    static let shared = OpenCodeMCPService()

    private let sshService: SSHService
    private let clientOverride: OpenCodeClient?

    init(sshService: SSHService? = nil, client: OpenCodeClient? = nil) {
        self.sshService = sshService ?? ServiceManager.shared.sshService
        self.clientOverride = client
    }

    /// Fast read of configured MCP servers + live status. Does **not** provision or connect.
    func fetchServers(for project: RemoteProject, scope: MCPServer.MCPScope? = nil) async throws -> [MCPServer] {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        let document = try await loadConfiguration(for: project, scope: scope ?? .project, session: session).document
        let statuses = await liveStatuses(for: project)

        var serversByName: [String: MCPServer] = [:]
        for var server in document.servers {
            if let status = statuses[server.name] {
                server.status = status.mcpStatus
                server.statusError = status.error
            }
            serversByName[server.name] = server
        }

        return serversByName.values.sorted { $0.name < $1.name }
    }

    /// Whether a named project MCP entry already exists in opencode config (no live status).
    func projectHasServer(named name: String, for project: RemoteProject) async throws -> Bool {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        let document = try await loadConfiguration(for: project, scope: .project, session: session).document
        return document.server(named: name) != nil
    }

    /// Best-effort connect for a live OpenCode process (used after first-time provision only).
    func connectServerIfNeeded(named name: String, for project: RemoteProject) async {
        await connectLiveServer(name: name, for: project)
    }

    func addServer(
        _ server: MCPServer,
        scope: MCPServer.MCPScope = .project,
        for project: RemoteProject,
        allowManaged: Bool = false,
        enabled: Bool? = nil
    ) async throws {
        try validateManagedServerWrite(server.name, server: server, allowManaged: allowManaged)

        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        var loaded = try await loadConfiguration(for: project, scope: scope, session: session)
        let previousJSON = try loaded.document.toJSONString()
        let existingConfiguration = loaded.document.serverConfigurations()[server.name]
        let resolvedEnabled = enabled ?? existingConfiguration?.enabled ?? true
        var configuration = existingConfiguration?.mergingEditableFields(
            from: server,
            defaultEnabled: resolvedEnabled
        ) ?? OpenCodeMCPServerConfiguration(server: server, enabled: resolvedEnabled)
        configuration?.enabled = resolvedEnabled
        guard let configuration else {
            throw MCPServiceError.invalidConfiguration("Cannot convert MCP server to OpenCode configuration")
        }
        try loaded.document.setServer(named: server.name, configuration: configuration)
        let didWrite = try await writeConfigurationIfChanged(
            loaded.document,
            previousJSON: previousJSON,
            to: loaded.path,
            session: session
        )
        // Live POST is expensive; only when config actually changed.
        if didWrite {
            await addLiveServer(name: server.name, configuration: configuration, for: project)
        }
    }

    /// Write a full project MCP configuration (preserves `oauth`, `timeout`, and other fields lost by `MCPServer` round-trip).
    /// - Returns: `true` when the on-disk config changed (and live add was attempted).
    @discardableResult
    func addServerConfiguration(
        named name: String,
        configuration: OpenCodeMCPServerConfiguration,
        scope: MCPServer.MCPScope = .project,
        for project: RemoteProject,
        allowManaged: Bool = false,
        activateLive: Bool = true
    ) async throws -> Bool {
        let synthetic = MCPServer(name: name, openCodeConfiguration: configuration)
            ?? MCPServer(name: name, command: nil, args: nil, env: nil, url: configuration.url, headers: configuration.headers)
        try validateManagedServerWrite(name, server: synthetic, allowManaged: allowManaged)

        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        var loaded = try await loadConfiguration(for: project, scope: scope, session: session)
        let previousJSON = try loaded.document.toJSONString()
        try loaded.document.setServer(named: name, configuration: configuration)
        let didWrite = try await writeConfigurationIfChanged(
            loaded.document,
            previousJSON: previousJSON,
            to: loaded.path,
            session: session
        )
        if activateLive {
            await addLiveServer(name: name, configuration: configuration, for: project)
        }
        return didWrite
    }

    /// Disable a host-global server for one project and keep disk/runtime state
    /// coherent. If the live OpenCode update fails, restore the prior project
    /// entry and effective live configuration so the action remains retryable.
    @discardableResult
    func disableHostServerForProject(
        named name: String,
        hostConfiguration: OpenCodeMCPServerConfiguration,
        for project: RemoteProject
    ) async throws -> Bool {
        let synthetic = MCPServer(name: name, openCodeConfiguration: hostConfiguration)
            ?? MCPServer(
                name: name,
                command: nil,
                args: nil,
                env: nil,
                url: hostConfiguration.url,
                headers: hostConfiguration.headers
            )
        try validateManagedServerWrite(name, server: synthetic, allowManaged: false)

        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        var loaded = try await loadConfiguration(for: project, scope: .project, session: session)
        let previousJSON = try loaded.document.toJSONString()
        let previousProjectConfiguration = loaded.document.serverConfigurations()[name]
        let previousLiveConfiguration = previousProjectConfiguration ?? hostConfiguration

        var disabledConfiguration = hostConfiguration
        disabledConfiguration.enabled = false
        try loaded.document.setServer(named: name, configuration: disabledConfiguration)
        let didWrite = try await writeConfigurationIfChanged(
            loaded.document,
            previousJSON: previousJSON,
            to: loaded.path,
            session: session
        )

        do {
            try await applyLiveServerConfiguration(
                name: name,
                configuration: disabledConfiguration,
                for: project
            )
        } catch {
            let rollbackError = await rollbackProjectServerMutation(
                named: name,
                previousProjectConfiguration: previousProjectConfiguration,
                previousLiveConfiguration: previousLiveConfiguration,
                mutatedDocument: loaded.document,
                path: loaded.path,
                session: session,
                project: project
            )
            if let rollbackError {
                throw MCPServiceError.commandFailed(
                    "Live disable failed: \(error.localizedDescription). "
                        + "Rollback also failed: \(rollbackError.localizedDescription)"
                )
            }
            throw error
        }

        return didWrite
    }

    /// Project-scope MCP server configurations including `enabled` (for accurate clone).
    func projectServerConfigurations(for project: RemoteProject) async throws -> [String: OpenCodeMCPServerConfiguration] {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        let loaded = try await loadConfiguration(for: project, scope: .project, session: session)
        return loaded.document.serverConfigurations()
    }

    /// Write many project MCP servers in **one** load/write of `opencode.json`.
    /// - Parameter activateLive: When true, also POSTs each server to a live OpenCode process (slow).
    ///   Duplicate Agent leaves this false — OpenCode picks up config on next session open.
    func writeProjectServerConfigurations(
        _ configurations: [String: OpenCodeMCPServerConfiguration],
        for project: RemoteProject,
        activateLive: Bool = false
    ) async throws {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        var loaded = try await loadConfiguration(for: project, scope: .project, session: session)
        let previousJSON = try loaded.document.toJSONString()

        for (name, configuration) in configurations {
            let synthetic = MCPServer(name: name, openCodeConfiguration: configuration)
                ?? MCPServer(
                    name: name,
                    command: nil,
                    args: nil,
                    env: nil,
                    url: configuration.url,
                    headers: configuration.headers
                )
            try validateManagedServerWrite(name, server: synthetic, allowManaged: MCPServer.isManagedServer(name))
            try loaded.document.setServer(named: name, configuration: configuration)
        }

        try await writeConfigurationIfChanged(
            loaded.document,
            previousJSON: previousJSON,
            to: loaded.path,
            session: session
        )

        guard activateLive else { return }
        for (name, configuration) in configurations.sorted(by: { $0.key < $1.key }) {
            await addLiveServer(name: name, configuration: configuration, for: project)
        }
    }

    func removeServer(
        named name: String,
        scope: MCPServer.MCPScope? = nil,
        for project: RemoteProject,
        allowManaged: Bool = false
    ) async throws {
        guard allowManaged || !MCPServer.isManagedServer(name) else {
            throw MCPServiceError.managedServerNotModifiable
        }

        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        var loaded = try await loadConfiguration(for: project, scope: scope ?? .project, session: session)
        let previousJSON = try loaded.document.toJSONString()
        loaded.document.removeServer(named: name)
        try await writeConfigurationIfChanged(loaded.document, previousJSON: previousJSON, to: loaded.path, session: session)
        await disconnectLiveServer(name: name, for: project)
    }

    /// Remove a project override and immediately apply the effective host
    /// configuration to the active project runtime.
    ///
    /// Dynamic add replaces the current MCP client, so this intentionally does
    /// not disconnect first and avoids a window where the host fallback is
    /// present on disk but unavailable to the running OpenCode process.
    func revertProjectServerOverride(
        named name: String,
        restoring hostConfiguration: OpenCodeMCPServerConfiguration,
        for project: RemoteProject
    ) async throws {
        guard !MCPServer.isManagedServer(name) else {
            throw MCPServiceError.managedServerNotModifiable
        }

        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        var loaded = try await loadConfiguration(for: project, scope: .project, session: session)
        let previousJSON = try loaded.document.toJSONString()
        guard let previousProjectConfiguration = loaded.document.serverConfigurations()[name] else {
            throw MCPServiceError.serverNotFound
        }
        loaded.document.removeServer(named: name)
        try await writeConfigurationIfChanged(
            loaded.document,
            previousJSON: previousJSON,
            to: loaded.path,
            session: session
        )

        do {
            try await applyLiveServerConfiguration(
                name: name,
                configuration: hostConfiguration,
                for: project
            )
        } catch {
            let rollbackError = await rollbackProjectServerMutation(
                named: name,
                previousProjectConfiguration: previousProjectConfiguration,
                previousLiveConfiguration: previousProjectConfiguration,
                mutatedDocument: loaded.document,
                path: loaded.path,
                session: session,
                project: project
            )
            if let rollbackError {
                throw MCPServiceError.commandFailed(
                    "Live revert failed: \(error.localizedDescription). "
                        + "Rollback also failed: \(rollbackError.localizedDescription)"
                )
            }
            throw error
        }
    }

    func editServer(
        oldName: String,
        newServer: MCPServer,
        scope: MCPServer.MCPScope = .project,
        for project: RemoteProject,
        allowManaged: Bool = false
    ) async throws {
        guard allowManaged || !MCPServer.isManagedServer(oldName) else {
            throw MCPServiceError.managedServerNotModifiable
        }
        try validateManagedServerWrite(newServer.name, server: newServer, allowManaged: allowManaged)

        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        var loaded = try await loadConfiguration(for: project, scope: scope, session: session)
        let previousJSON = try loaded.document.toJSONString()
        var originalConfiguration = loaded.document.serverConfigurations()[oldName]
        if originalConfiguration == nil, scope == .project,
           let hostPath = try? await globalConfigurationPath(session: session),
           let hostDocument = try? await readConfiguration(at: hostPath, session: session) {
            // Creating a project override starts with the full host definition,
            // including fields the editor does not expose.
            originalConfiguration = hostDocument.serverConfigurations()[oldName]
        }

        let configuration = originalConfiguration?.mergingEditableFields(from: newServer)
            ?? OpenCodeMCPServerConfiguration(server: newServer, enabled: true)
        guard let configuration else {
            throw MCPServiceError.invalidConfiguration("Cannot convert MCP server to OpenCode configuration")
        }
        loaded.document.removeServer(named: oldName)
        try loaded.document.setServer(named: newServer.name, configuration: configuration)
        try await writeConfigurationIfChanged(loaded.document, previousJSON: previousJSON, to: loaded.path, session: session)

        if oldName != newServer.name {
            await disconnectLiveServer(name: oldName, for: project)
        }
        await addLiveServer(name: newServer.name, configuration: configuration, for: project)
    }

    func getServer(named name: String, for project: RemoteProject) async throws -> MCPServer? {
        let details = try await getServerDetails(named: name, scope: nil, for: project)
        return details?.server
    }

    func getServerDetails(
        named name: String,
        scope: MCPServer.MCPScope? = nil,
        for project: RemoteProject
    ) async throws -> (server: MCPServer, scope: MCPServer.MCPScope)? {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        let scopesToSearch: [MCPServer.MCPScope] = scope.map { [$0] } ?? [.project, .global]
        let statuses = await liveStatuses(for: project)

        for scope in scopesToSearch {
            let loaded = try await loadConfiguration(for: project, scope: scope, session: session)
            guard var server = loaded.document.server(named: name) else {
                continue
            }
            if let status = statuses[name] {
                server.status = status.mcpStatus
                server.statusError = status.error
            }
            return (server, scope)
        }

        return nil
    }

    // MARK: - Host-scoped (no RemoteProject required)

    /// Read MCP servers from a host's global OpenCode config (`~/.config/opencode/opencode.json`)
    /// without requiring an active project. Live status is best-effort and uses `directory: nil`.
    func fetchGlobalServers(for server: Server) async throws -> [MCPServer] {
        let session = try await sshService.getConnection(for: server, purpose: .fileOperations)
        let path = try await globalConfigurationPath(session: session)
        let document = try await readConfiguration(at: path, session: session)
        let statuses = await liveStatuses(for: server)

        var serversByName: [String: MCPServer] = [:]
        for var serverEntry in document.servers {
            if let status = statuses[serverEntry.name] {
                serverEntry.status = status.mcpStatus
                serverEntry.statusError = status.error
            }
            serversByName[serverEntry.name] = serverEntry
        }
        return serversByName.values.sorted { $0.name < $1.name }
    }

    /// Raw global configurations (preserves `oauth`, `timeout`, and unknown fields) for cross-host copy.
    func globalServerConfigurations(for server: Server) async throws -> [String: OpenCodeMCPServerConfiguration] {
        let session = try await sshService.getConnection(for: server, purpose: .fileOperations)
        let path = try await globalConfigurationPath(session: session)
        let document = try await readConfiguration(at: path, session: session)
        return document.serverConfigurations()
    }

    /// Add a global MCP server to a host (no project required).
    func addServer(
        _ server: MCPServer,
        to host: Server,
        enabled: Bool? = nil
    ) async throws {
        try validateManagedServerWrite(server.name, server: server, allowManaged: false)

        let session = try await sshService.getConnection(for: host, purpose: .fileOperations)
        let path = try await globalConfigurationPath(session: session)
        var document = try await readConfiguration(at: path, session: session)
        let previousJSON = try document.toJSONString()
        let existingConfiguration = document.serverConfigurations()[server.name]
        let resolvedEnabled = enabled ?? existingConfiguration?.enabled ?? true
        var configuration = existingConfiguration?.mergingEditableFields(
            from: server,
            defaultEnabled: resolvedEnabled
        ) ?? OpenCodeMCPServerConfiguration(server: server, enabled: resolvedEnabled)
        configuration?.enabled = resolvedEnabled
        guard let configuration else {
            throw MCPServiceError.invalidConfiguration("Cannot convert MCP server to OpenCode configuration")
        }
        try document.setServer(named: server.name, configuration: configuration)
        let didWrite = try await writeConfigurationIfChanged(
            document,
            previousJSON: previousJSON,
            to: path,
            session: session
        )
        if didWrite {
            await addLiveServer(name: server.name, configuration: configuration, for: host)
        }
    }

    /// Write a raw OpenCode MCP configuration to a host's global config. Preserves `oauth`,
    /// `timeout`, and other fields lost by the `MCPServer` round-trip — use this for
    /// cross-host copies, not `addServer(_:to:)`.
    @discardableResult
    func addServerConfiguration(
        _ configuration: OpenCodeMCPServerConfiguration,
        named name: String,
        to host: Server,
        enabled: Bool? = nil,
        allowManaged: Bool = false
    ) async throws -> Bool {
        let synthetic = MCPServer(name: name, openCodeConfiguration: configuration)
            ?? MCPServer(
                name: name,
                command: nil,
                args: nil,
                env: nil,
                url: configuration.url,
                headers: configuration.headers
            )
        try validateManagedServerWrite(name, server: synthetic, allowManaged: allowManaged)

        let session = try await sshService.getConnection(for: host, purpose: .fileOperations)
        let path = try await globalConfigurationPath(session: session)
        var document = try await readConfiguration(at: path, session: session)
        let previousJSON = try document.toJSONString()

        var resolvedConfiguration = configuration
        if let enabled {
            resolvedConfiguration.enabled = enabled
        } else if document.serverConfigurations()[name]?.enabled == nil {
            resolvedConfiguration.enabled = true
        }
        try document.setServer(named: name, configuration: resolvedConfiguration)
        let didWrite = try await writeConfigurationIfChanged(
            document,
            previousJSON: previousJSON,
            to: path,
            session: session
        )
        if didWrite {
            await addLiveServer(name: name, configuration: resolvedConfiguration, for: host)
        }
        return didWrite
    }

    /// Remove a global MCP server from a host (no project required).
    func removeServer(
        named name: String,
        from host: Server,
        allowManaged: Bool = false
    ) async throws {
        guard allowManaged || !MCPServer.isManagedServer(name) else {
            throw MCPServiceError.managedServerNotModifiable
        }

        let session = try await sshService.getConnection(for: host, purpose: .fileOperations)
        let path = try await globalConfigurationPath(session: session)
        var document = try await readConfiguration(at: path, session: session)
        let previousJSON = try document.toJSONString()
        document.removeServer(named: name)
        try await writeConfigurationIfChanged(
            document,
            previousJSON: previousJSON,
            to: path,
            session: session
        )
        await disconnectLiveServer(name: name, for: host)
    }

    /// Rename / replace a global MCP server on a host (no project required).
    func editServer(
        oldName: String,
        newServer: MCPServer,
        on host: Server,
        allowManaged: Bool = false
    ) async throws {
        guard allowManaged || !MCPServer.isManagedServer(oldName) else {
            throw MCPServiceError.managedServerNotModifiable
        }
        try validateManagedServerWrite(newServer.name, server: newServer, allowManaged: allowManaged)

        let session = try await sshService.getConnection(for: host, purpose: .fileOperations)
        let path = try await globalConfigurationPath(session: session)
        var document = try await readConfiguration(at: path, session: session)
        let previousJSON = try document.toJSONString()
        let originalConfiguration = document.serverConfigurations()[oldName]
        let configuration = originalConfiguration?.mergingEditableFields(from: newServer)
            ?? OpenCodeMCPServerConfiguration(server: newServer, enabled: true)
        guard let configuration else {
            throw MCPServiceError.invalidConfiguration("Cannot convert MCP server to OpenCode configuration")
        }
        document.removeServer(named: oldName)
        try document.setServer(named: newServer.name, configuration: configuration)
        try await writeConfigurationIfChanged(
            document,
            previousJSON: previousJSON,
            to: path,
            session: session
        )

        if oldName != newServer.name {
            await disconnectLiveServer(name: oldName, for: host)
        }
        await addLiveServer(name: newServer.name, configuration: configuration, for: host)
    }

    func configurationPreview(for server: MCPServer, scope: MCPServer.MCPScope) -> String {
        guard let configuration = OpenCodeMCPServerConfiguration(server: server) else {
            return "Invalid configuration"
        }

        do {
            let data = try JSONEncoder.openCodePretty.encode(OpenCodeMCPAddPayloadPreview(name: server.name, config: configuration))
            return String(data: data, encoding: .utf8) ?? "Invalid configuration"
        } catch {
            return "Invalid configuration"
        }
    }

    /// Import Claude `.mcp.json` (and optional CLI fallback) servers into project OpenCode config.
    /// Idempotent: existing OpenCode names are kept; managed scheduler is never copied from Claude.
    func importServersFromClaudeIfNeeded(
        for project: RemoteProject,
        claudeServersOverride: [MCPServer]? = nil
    ) async throws -> MCPMigrationReport {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        var loaded = try await loadConfiguration(for: project, scope: .project, session: session)
        let previousJSON = try loaded.document.toJSONString()

        let claudeServers: [MCPServer]
        if let claudeServersOverride {
            claudeServers = claudeServersOverride
        } else {
            claudeServers = try await loadClaudeMCPServers(for: project, session: session)
        }

        guard !claudeServers.isEmpty else {
            var empty = MCPMigrationReport()
            empty.note = "no_claude_mcp_source"
            return empty
        }

        let mergeResult = MCPClaudeToOpenCodeMigrator.merge(servers: claudeServers, into: loaded.document)
        loaded.document = mergeResult.document
        let report = mergeResult.report

        try await writeConfigurationIfChanged(
            loaded.document,
            previousJSON: previousJSON,
            to: loaded.path,
            session: session
        )

        // Live-register imported servers when OpenCode is up (soft-fail per server).
        let configurations = loaded.document.serverConfigurations()
        for name in report.imported {
            guard let configuration = configurations[name] else { continue }
            await addLiveServer(name: name, configuration: configuration, for: project)
        }

        return report
    }

    private func loadClaudeMCPServers(for project: RemoteProject, session: SSHSession) async throws -> [MCPServer] {
        let claudePath = "\(project.path)/.mcp.json"
        if let contents = try await readFileIfPresent(at: claudePath, session: session) {
            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                do {
                    return try MCPClaudeToOpenCodeMigrator.servers(fromClaudeMCPJSON: trimmed)
                } catch {
                    SSHLogger.log(
                        "Failed to parse Claude .mcp.json for migration: \(error.localizedDescription)",
                        level: .warning
                    )
                }
            }
        }

        // Optional CLI fallback is handled by CodingAgentMCPService when file is empty.
        return []
    }

    private func readFileIfPresent(at path: String, session: SSHSession) async throws -> String? {
        do {
            return try await session.readFile(path)
        } catch {
            let errorMessage = error.localizedDescription.lowercased()
            if errorMessage.contains("no such file") || errorMessage.contains("cannot open") {
                return nil
            }
            throw error
        }
    }

    private func validateManagedServerWrite(_ name: String, server: MCPServer, allowManaged: Bool) throws {
        guard MCPServer.isManagedServer(name) else { return }
        if allowManaged {
            return
        }
        if MCPServer.isManagedSchedulerServer(name), server.matchesManagedSchedulerDefinition() {
            throw MCPServiceError.managedServerNotModifiable
        }
        throw MCPServiceError.managedServerNotModifiable
    }

    private func liveStatuses(for project: RemoteProject) async -> [String: OpenCodeMCPStatus] {
        do {
            let session = try await sshService.getConnection(for: project, purpose: .opencode)
            let client = client(for: project)
            return try await client.mcpStatus(sshSession: session, directory: project.path)
        } catch {
            SSHLogger.log("OpenCode MCP status unavailable: \(error.localizedDescription)", level: .warning)
            return [:]
        }
    }

    private func addLiveServer(
        name: String,
        configuration: OpenCodeMCPServerConfiguration,
        for project: RemoteProject
    ) async {
        do {
            try await applyLiveServerConfiguration(
                name: name,
                configuration: configuration,
                for: project
            )
        } catch {
            SSHLogger.log("OpenCode MCP add live refresh failed: \(error.localizedDescription)", level: .warning)
        }
    }

    private func applyLiveServerConfiguration(
        name: String,
        configuration: OpenCodeMCPServerConfiguration,
        for project: RemoteProject
    ) async throws {
        let session = try await sshService.getConnection(for: project, purpose: .opencode)
        let client = client(for: project)
        let statuses = try await client.addMCPServer(
            sshSession: session,
            name: name,
            config: configuration,
            directory: project.path
        )
        try validateLiveApplication(
            named: name,
            configuration: configuration,
            statuses: statuses
        )
    }

    private func validateLiveApplication(
        named name: String,
        configuration: OpenCodeMCPServerConfiguration,
        statuses: [String: OpenCodeMCPStatus]
    ) throws {
        guard let result = statuses[name] else {
            throw MCPServiceError.commandFailed(
                "OpenCode did not return live status for \(name)"
            )
        }

        let status = result.status.lowercased()
        if configuration.enabled == false {
            guard status == "disabled" else {
                throw MCPServiceError.commandFailed(
                    "OpenCode returned \(status) instead of disabled for \(name)"
                )
            }
            return
        }

        // An enabled configuration is considered applied when its client is
        // connected or waiting for an explicit OAuth/client-registration step.
        // Disabled, failed, missing, and unknown states are not accepted.
        let appliedEnabledStatuses: Set<String> = [
            "connected",
            "needs_auth",
            "needs_client_registration"
        ]
        guard appliedEnabledStatuses.contains(status) else {
            let detail = result.error.map { ": \($0)" } ?? ""
            throw MCPServiceError.commandFailed(
                "OpenCode returned \(status) for \(name)\(detail)"
            )
        }
    }

    /// Restore both project config and live state after a strict runtime update
    /// fails. Returning an error lets the caller report a partial rollback while
    /// still preserving the original operation error when compensation succeeds.
    private func rollbackProjectServerMutation(
        named name: String,
        previousProjectConfiguration: OpenCodeMCPServerConfiguration?,
        previousLiveConfiguration: OpenCodeMCPServerConfiguration,
        mutatedDocument: OpenCodeMCPConfigDocument,
        path: String,
        session: SSHSession,
        project: RemoteProject
    ) async -> Error? {
        var failures: [String] = []

        do {
            let mutatedJSON = try mutatedDocument.toJSONString()
            var restoredDocument = mutatedDocument
            if let previousProjectConfiguration {
                try restoredDocument.setServer(
                    named: name,
                    configuration: previousProjectConfiguration
                )
            } else {
                restoredDocument.removeServer(named: name)
            }
            try await writeConfigurationIfChanged(
                restoredDocument,
                previousJSON: mutatedJSON,
                to: path,
                session: session
            )
        } catch {
            failures.append("disk restore: \(error.localizedDescription)")
        }

        do {
            try await applyLiveServerConfiguration(
                name: name,
                configuration: previousLiveConfiguration,
                for: project
            )
        } catch {
            failures.append("live restore: \(error.localizedDescription)")
        }

        guard !failures.isEmpty else {
            return nil
        }
        return MCPServiceError.commandFailed(failures.joined(separator: "; "))
    }

    private func disconnectLiveServer(name: String, for project: RemoteProject) async {
        do {
            let session = try await sshService.getConnection(for: project, purpose: .opencode)
            let client = client(for: project)
            _ = try await client.disconnectMCPServer(sshSession: session, name: name, directory: project.path)
        } catch {
            SSHLogger.log("OpenCode MCP disconnect failed: \(error.localizedDescription)", level: .warning)
        }
    }

    private func connectLiveServer(name: String, for project: RemoteProject) async {
        do {
            let session = try await sshService.getConnection(for: project, purpose: .opencode)
            let client = client(for: project)
            _ = try await client.connectMCPServer(sshSession: session, name: name, directory: project.path)
        } catch {
            SSHLogger.log("OpenCode MCP connect failed for \(name): \(error.localizedDescription)", level: .warning)
        }
    }

    // MARK: - Host-scoped live helpers (Server, no project directory)

    /// Live MCP status from a host's running OpenCode, using `directory: nil` for global scope.
    private func liveStatuses(for host: Server) async -> [String: OpenCodeMCPStatus] {
        do {
            let session = try await sshService.getConnection(for: host, purpose: .opencode)
            let client = client(for: host)
            return try await client.mcpStatus(sshSession: session, directory: nil)
        } catch {
            SSHLogger.log(
                "OpenCode MCP status unavailable for host \(host.name): \(error.localizedDescription)",
                level: .warning
            )
            return [:]
        }
    }

    private func addLiveServer(
        name: String,
        configuration: OpenCodeMCPServerConfiguration,
        for host: Server
    ) async {
        do {
            let session = try await sshService.getConnection(for: host, purpose: .opencode)
            let client = client(for: host)
            _ = try await client.addMCPServer(
                sshSession: session,
                name: name,
                config: configuration,
                directory: nil
            )
        } catch {
            SSHLogger.log(
                "OpenCode MCP add live refresh failed for host \(host.name): \(error.localizedDescription)",
                level: .warning
            )
        }
    }

    private func disconnectLiveServer(name: String, for host: Server) async {
        do {
            let session = try await sshService.getConnection(for: host, purpose: .opencode)
            let client = client(for: host)
            _ = try await client.disconnectMCPServer(sshSession: session, name: name, directory: nil)
        } catch {
            SSHLogger.log(
                "OpenCode MCP disconnect failed for host \(host.name): \(error.localizedDescription)",
                level: .warning
            )
        }
    }

    private func client(for host: Server) -> OpenCodeClient {
        clientOverride ?? OpenCodeClientFactory.client(for: host.id)
    }

    private func client(for project: RemoteProject) -> OpenCodeClient {
        clientOverride ?? OpenCodeClientFactory.client(for: project.serverId)
    }

    private func loadConfiguration(
        for project: RemoteProject,
        scope: MCPServer.MCPScope,
        session: SSHSession
    ) async throws -> (path: String, document: OpenCodeMCPConfigDocument) {
        if scope == .global {
            let path = try await globalConfigurationPath(session: session)
            return (path, try await readConfiguration(at: path, session: session))
        }

        let jsonPath = "\(project.path)/opencode.json"
        if let document = try await readConfigurationIfPresent(at: jsonPath, session: session) {
            return (jsonPath, document)
        }

        let jsoncPath = "\(project.path)/opencode.jsonc"
        if let document = try await readConfigurationIfPresent(at: jsoncPath, session: session) {
            return (jsoncPath, document)
        }

        return (jsonPath, OpenCodeMCPConfigDocument())
    }

    private func readConfiguration(at path: String, session: SSHSession) async throws -> OpenCodeMCPConfigDocument {
        if let document = try await readConfigurationIfPresent(at: path, session: session) {
            return document
        }
        return OpenCodeMCPConfigDocument()
    }

    private func readConfigurationIfPresent(
        at path: String,
        session: SSHSession
    ) async throws -> OpenCodeMCPConfigDocument? {
        do {
            return try OpenCodeMCPConfigDocument(jsonString: try await session.readFile(path))
        } catch {
            let errorMessage = error.localizedDescription.lowercased()
            if errorMessage.contains("no such file") || errorMessage.contains("cannot open") {
                return nil
            }
            throw error
        }
    }

    /// - Returns: `true` when bytes were written.
    @discardableResult
    private func writeConfigurationIfChanged(
        _ document: OpenCodeMCPConfigDocument,
        previousJSON: String,
        to path: String,
        session: SSHSession
    ) async throws -> Bool {
        let nextJSON = try document.toJSONString()
        guard nextJSON != previousJSON else {
            SSHLogger.log("Skipping unchanged OpenCode MCP configuration write: \(path)", level: .debug)
            return false
        }

        guard let data = nextJSON.data(using: .utf8) else {
            throw MCPConfigurationError.encodingFailed
        }
        let base64 = data.base64EncodedString()
        let escapedPath = escapeForDoubleQuotes(path)
        let command = "mkdir -p \"$(dirname \"\(escapedPath)\")\" && printf '%s' '\(base64)' | base64 -d > \"\(escapedPath)\""
        _ = try await session.execute(command)
        return true
    }

    private func globalConfigurationPath(session: SSHSession) async throws -> String {
        let command = "printf '%s' \"${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json\""
        let path = try await session.execute(command).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw MCPServiceError.invalidConfiguration("Unable to resolve OpenCode global config path")
        }
        return path
    }

    private func escapeForDoubleQuotes(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }
}

private struct OpenCodeMCPAddPayloadPreview: Encodable {
    let name: String
    let config: OpenCodeMCPServerConfiguration
}

private extension JSONEncoder {
    static var openCodePretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
