//
//  MCPService.swift
//  CodeAgentsMobile
//
//  Purpose: Service for managing MCP (Model Context Protocol) servers
//  Uses hybrid approach: reads .mcp.json for config, claude mcp list for status
//

import Foundation

/// Service for managing MCP servers
@MainActor
class MCPService: ObservableObject {
    static let shared = MCPService()
    
    private let sshService = ServiceManager.shared.sshService
    
    // MARK: - Public Methods
    
    /// Fetch MCP servers with configuration and status for a project
    func fetchServers(for project: RemoteProject, scope: MCPServer.MCPScope? = nil) async throws -> [MCPServer] {
        // Get server list and status from claude mcp list
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)

        let command = "cd \"\(project.path)\" && claude mcp list"
        
        SSHLogger.log("Fetching MCP servers: \(command)", level: .debug)
        
        do {
            let result = try await session.execute(command)
            
            // Check for command not found
            if result.contains("claude: command not found") {
                throw MCPServiceError.claudeNotInstalled
            }
            
            // Parse the output to get server info
            let serverInfos = MCPStatusParser.parseServerList(result)
            
            // Convert to MCPServer objects
            var servers: [MCPServer] = []
            for info in serverInfos {
                var server = MCPServer(
                    name: info.name,
                    command: info.command,  // This is the full command line from claude mcp list
                    args: nil,
                    env: nil,
                    url: nil,
                    headers: nil
                )
                server.status = info.status
                servers.append(server)
            }
            
            return servers.sorted { $0.name < $1.name }
            
        } catch {
            SSHLogger.log("Failed to fetch MCP servers: \(error)", level: .warning)
            throw error
        }
    }
    
    /// Add a new MCP server using claude mcp add-json
    func addServer(_ server: MCPServer, scope: MCPServer.MCPScope = .project, for project: RemoteProject, allowManaged: Bool = false) async throws {
        if MCPServer.isManagedSchedulerServer(server.name) && !server.matchesManagedSchedulerDefinition() {
            throw MCPServiceError.managedServerNotModifiable
        }
        guard allowManaged || !MCPServer.isManagedSchedulerServer(server.name) else {
            throw MCPServiceError.managedServerNotModifiable
        }

        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        
        // Generate the claude mcp add-json command
        guard let command = server.generateAddJsonCommand(scope: scope) else {
            throw MCPServiceError.invalidConfiguration("Cannot generate command for server")
        }
        let fullCommand = "cd \"\(project.path)\" && \(command)"
        
        SSHLogger.log("Adding MCP server with add-json: \(fullCommand)", level: .info)
        
        let result = try await session.execute(fullCommand)
        
        // Check for errors in output
        if MCPStatusParser.isErrorOutput(result) {
            if let error = MCPStatusParser.extractError(result) {
                throw MCPServiceError.commandFailed(error)
            }
        }
    }
    
    /// Remove an MCP server
    func removeServer(named name: String, scope: MCPServer.MCPScope? = nil, for project: RemoteProject, allowManaged: Bool = false) async throws {
        guard allowManaged || !MCPServer.isManagedSchedulerServer(name) else {
            throw MCPServiceError.managedServerNotModifiable
        }

        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)

        let scopeArgument = scope.flatMap { $0 == .project ? nil : $0.rawValue }
        let command = "cd \"\(project.path)\" && claude mcp remove\(scopeArgument.map { " -s \($0)" } ?? "") \"\(name)\""
        
        SSHLogger.log("Removing MCP server: \(command)", level: .info)
        
        let result = try await session.execute(command)
        
        // Check for errors
        if MCPStatusParser.isErrorOutput(result) {
            if let error = MCPStatusParser.extractError(result) {
                throw MCPServiceError.commandFailed(error)
            }
        }
    }
    
    /// Edit an MCP server by removing and re-adding it
    func editServer(oldName: String, newServer: MCPServer, scope: MCPServer.MCPScope = .project, for project: RemoteProject, allowManaged: Bool = false) async throws {
        guard allowManaged || !MCPServer.isManagedSchedulerServer(oldName) else {
            throw MCPServiceError.managedServerNotModifiable
        }
        if MCPServer.isManagedSchedulerServer(newServer.name) && !newServer.matchesManagedSchedulerDefinition() {
            throw MCPServiceError.managedServerNotModifiable
        }
        guard allowManaged || !MCPServer.isManagedSchedulerServer(newServer.name) else {
            throw MCPServiceError.managedServerNotModifiable
        }

        if MCPServer.isManagedSchedulerServer(oldName) && !newServer.matchesManagedSchedulerDefinition() {
            throw MCPServiceError.managedServerNotModifiable
        }

        // First remove the old server
        try await removeServer(named: oldName, scope: scope, for: project, allowManaged: true)
        
        // Then add the new configuration
        try await addServer(newServer, scope: scope, for: project, allowManaged: allowManaged)
    }
    
    /// Get details of a specific server
    func getServer(named name: String, for project: RemoteProject) async throws -> MCPServer? {
        let servers = try await fetchServers(for: project)
        return servers.first { $0.name == name }
    }
    
    /// Get detailed information about a specific MCP server including env vars
    func getServerDetails(named name: String, scope: MCPServer.MCPScope? = nil, for project: RemoteProject) async throws -> (server: MCPServer, scope: MCPServer.MCPScope)? {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)

        let command = "cd \"\(project.path)\" && claude mcp get \"\(name)\""
        
        SSHLogger.log("Getting MCP server details: \(command)", level: .debug)
        
        do {
            let result = try await session.execute(command)
            
            // Check for errors
            if result.contains("Server not found") || result.contains("No server named") {
                SSHLogger.log("MCP server not found: \(name)", level: .warning)
                return nil
            }
            
            if result.contains("claude: command not found") {
                throw MCPServiceError.claudeNotInstalled
            }
            
            // Parse the detailed output
            return MCPStatusParser.parseServerDetails(result)
            
        } catch {
            SSHLogger.log("Failed to get MCP server details: \(error)", level: .error)
            throw error
        }
    }
    
}

// MARK: - Error Types
enum MCPServiceError: LocalizedError {
    case claudeNotInstalled
    case commandFailed(String)
    case invalidConfiguration(String)
    case permissionDenied
    case serverNotFound
    case managedServerNotModifiable
    
    var errorDescription: String? {
        switch self {
        case .claudeNotInstalled:
            return "Claude Code is not installed on this server"
        case .commandFailed(let message):
            return "Command failed: \(message)"
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        case .permissionDenied:
            return "Permission denied to modify .mcp.json"
        case .serverNotFound:
            return "MCP server not found"
        case .managedServerNotModifiable:
            return "This MCP server is managed by the app and cannot be changed here."
        }
    }
}
