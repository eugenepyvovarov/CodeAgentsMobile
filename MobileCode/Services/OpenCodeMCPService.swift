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

    func fetchServers(for project: RemoteProject, scope: MCPServer.MCPScope? = nil) async throws -> [MCPServer] {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        let document = try await loadConfiguration(for: project, scope: scope ?? .project, session: session).document
        let statuses = await liveStatuses(for: project)

        var serversByName: [String: MCPServer] = [:]
        for var server in document.servers {
            if let status = statuses[server.name] {
                server.status = status.mcpStatus
            }
            serversByName[server.name] = server
        }

        return serversByName.values.sorted { $0.name < $1.name }
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
        let previousEnabled = loaded.document.serverConfigurations()[server.name]?.enabled
        let resolvedEnabled = enabled ?? previousEnabled ?? true
        guard let configuration = OpenCodeMCPServerConfiguration(server: server, enabled: resolvedEnabled) else {
            throw MCPServiceError.invalidConfiguration("Cannot convert MCP server to OpenCode configuration")
        }
        try loaded.document.setServer(named: server.name, configuration: configuration)
        try await writeConfigurationIfChanged(loaded.document, previousJSON: previousJSON, to: loaded.path, session: session)
        await addLiveServer(name: server.name, configuration: configuration, for: project)
    }

    /// Write a full project MCP configuration (preserves `oauth`, `timeout`, and other fields lost by `MCPServer` round-trip).
    func addServerConfiguration(
        named name: String,
        configuration: OpenCodeMCPServerConfiguration,
        scope: MCPServer.MCPScope = .project,
        for project: RemoteProject,
        allowManaged: Bool = false
    ) async throws {
        let synthetic = MCPServer(name: name, openCodeConfiguration: configuration)
            ?? MCPServer(name: name, command: nil, args: nil, env: nil, url: configuration.url, headers: configuration.headers)
        try validateManagedServerWrite(name, server: synthetic, allowManaged: allowManaged)

        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        var loaded = try await loadConfiguration(for: project, scope: scope, session: session)
        let previousJSON = try loaded.document.toJSONString()
        try loaded.document.setServer(named: name, configuration: configuration)
        try await writeConfigurationIfChanged(loaded.document, previousJSON: previousJSON, to: loaded.path, session: session)
        await addLiveServer(name: name, configuration: configuration, for: project)
    }

    /// Project-scope MCP server configurations including `enabled` (for accurate clone).
    func projectServerConfigurations(for project: RemoteProject) async throws -> [String: OpenCodeMCPServerConfiguration] {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        let loaded = try await loadConfiguration(for: project, scope: .project, session: session)
        return loaded.document.serverConfigurations()
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
        let previousEnabled = loaded.document.serverConfigurations()[oldName]?.enabled
        guard let configuration = OpenCodeMCPServerConfiguration(server: newServer, enabled: previousEnabled ?? true) else {
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
            }
            return (server, scope)
        }

        return nil
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
            let session = try await sshService.getConnection(for: project, purpose: .opencode)
            let client = client(for: project)
            _ = try await client.addMCPServer(
                sshSession: session,
                name: name,
                config: configuration,
                directory: project.path
            )
        } catch {
            SSHLogger.log("OpenCode MCP add live refresh failed: \(error.localizedDescription)", level: .warning)
        }
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

    private func writeConfigurationIfChanged(
        _ document: OpenCodeMCPConfigDocument,
        previousJSON: String,
        to path: String,
        session: SSHSession
    ) async throws {
        let nextJSON = try document.toJSONString()
        guard nextJSON != previousJSON else {
            SSHLogger.log("Skipping unchanged OpenCode MCP configuration write: \(path)", level: .debug)
            return
        }

        guard let data = nextJSON.data(using: .utf8) else {
            throw MCPConfigurationError.encodingFailed
        }
        let base64 = data.base64EncodedString()
        let escapedPath = escapeForDoubleQuotes(path)
        let command = "mkdir -p \"$(dirname \"\(escapedPath)\")\" && printf '%s' '\(base64)' | base64 -d > \"\(escapedPath)\""
        _ = try await session.execute(command)
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
