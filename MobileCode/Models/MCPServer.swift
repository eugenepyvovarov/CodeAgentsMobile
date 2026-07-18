//
//  MCPServer.swift
//  CodeAgentsMobile
//
//  Purpose: Model for MCP (Model Context Protocol) server configuration
//  Represents both configuration data from .mcp.json and runtime status
//

import Foundation

/// Represents an MCP server with its configuration and runtime status
struct MCPServer: Identifiable, Equatable {
    let id = UUID()
    let name: String
    
    // Local server properties
    var command: String?
    var args: [String]?
    var env: [String: String]?
    
    // Remote server properties
    var url: String?
    var headers: [String: String]?
    
    // Runtime status (not persisted in .mcp.json)
    var status: MCPStatus = .unknown
    /// Live status detail from OpenCode (`/mcp`), when available.
    var statusError: String?

    static let managedSchedulerServerName = "codeagents-scheduled-tasks"
    static let managedSchedulerDisplayName = "Task Scheduler"
    static let managedAvatarServerName = "codeagents-avatar"
    static let managedAvatarDisplayName = "Agent Avatar"

    /// Expected built-in MCP server that powers scheduled-task tooling.
    /// Update this value if the proxy exposes scheduler tools through a different
    /// command or URL in your deployment.
    static let managedSchedulerServer = MCPServer(
        name: managedSchedulerServerName,
        command: nil,
        args: nil,
        env: nil,
        url: "http://127.0.0.1:8787/mcp",
        headers: nil
    )

    /// Whether this server is any app-managed MCP (scheduler, avatar, …).
    var isManagedServer: Bool {
        Self.isManagedServer(name)
    }

    /// Whether this server is the managed scheduler MCP server required by the app.
    var isManagedSchedulerServer: Bool {
        return name == MCPServer.managedSchedulerServerName
    }

    var isManagedAvatarServer: Bool {
        return name == MCPServer.managedAvatarServerName
    }

    /// Display name used in the UI.
    var displayName: String {
        if isManagedSchedulerServer {
            return MCPServer.managedSchedulerDisplayName
        }
        if isManagedAvatarServer {
            return MCPServer.managedAvatarDisplayName
        }
        return name
    }
    
    /// Whether this server matches the managed scheduler MCP definition.
    func matchesManagedSchedulerDefinition() -> Bool {
        return name == MCPServer.managedSchedulerServer.name &&
            (command ?? "") == (MCPServer.managedSchedulerServer.command ?? "") &&
            (args ?? []) == (MCPServer.managedSchedulerServer.args ?? []) &&
            (env ?? [:]) == (MCPServer.managedSchedulerServer.env ?? [:]) &&
            (url ?? "") == (MCPServer.managedSchedulerServer.url ?? "") &&
            (headers ?? [:]) == (MCPServer.managedSchedulerServer.headers ?? [:])
    }
    
    /// Server connection status
    enum MCPStatus: Equatable {
        case connected
        case disconnected
        case unknown
        case checking
        
        var displayColor: String {
            switch self {
            case .connected:
                return "green"
            case .disconnected:
                return "red"
            case .unknown:
                return "gray"
            case .checking:
                return "blue"
            }
        }
        
        var displayText: String {
            switch self {
            case .connected:
                return "Connected"
            case .disconnected:
                return "Disconnected"
            case .unknown:
                return "Unknown"
            case .checking:
                return "Checking..."
            }
        }
    }
    
    /// MCP scope: where the server configuration is stored on the remote host.
    enum MCPScope: String, CaseIterable {
        /// Project-scoped: written to `<project.path>/opencode.json`, shared via SCM with the team.
        case project = "project"
        /// Legacy Claude "local" concept. Retained for decoding old configs only; not surfaced in UI.
        /// OpenCode has no per-machine storage on the phone — every scope lives on the SSH host.
        case local = "local"
        /// Host-scoped (formerly "user"): written to `~/.config/opencode/opencode.json` on the host,
        /// available to every agent that lives on that host.
        case global = "user"

        var displayName: String {
            switch self {
            case .project:
                return "Project (Shared)"
            case .local:
                return "Local (Legacy)"
            case .global:
                return "Host (all agents on this server)"
            }
        }

        var description: String {
            switch self {
            case .project:
                return "Saved in opencode.json at the project path, shared via SCM"
            case .local:
                return "Legacy Claude concept; not used by OpenCode. Kept for decode compatibility only."
            case .global:
                return "Available in all agents on this server (host-level config)"
            }
        }
    }
    
    /// Full command with arguments for display
    var fullCommand: String {
        if let url = url {
            return url
        } else if let command = command {
            // Don't show "http" or "sse" as command for remote servers
            if command.lowercased() == "http" || command.lowercased() == "sse" {
                return "Remote MCP Server"
            }
            var parts = [command]
            if let args = args {
                parts.append(contentsOf: args)
            }
            return parts.joined(separator: " ")
        }
        return ""
    }
    
    /// Check if this is a remote server (has URL instead of command)
    var isRemote: Bool {
        if url != nil {
            return true
        }
        // Also check if command is "http" or "sse" which indicates remote server from claude mcp list
        if let command = command {
            return command.lowercased() == "http" || command.lowercased() == "sse"
        }
        return false
    }
    
    /// Generate the claude mcp add-json command for this server
    func generateAddJsonCommand(scope: MCPScope = .project) -> String? {
        // Create JSON configuration
        var jsonConfig: [String: Any] = [:]
        
        if let url = url {
            // Remote server - determine type based on URL
            // If URL contains "sse" (case-insensitive), use "sse", otherwise use "http"
            let serverType = url.lowercased().contains("sse") ? "sse" : "http"
            jsonConfig["type"] = serverType
            jsonConfig["url"] = url
            if let headers = headers {
                jsonConfig["headers"] = headers
            }
        } else if let command = command {
            // Local server
            jsonConfig["type"] = "stdio"
            jsonConfig["command"] = command
            if let args = args {
                jsonConfig["args"] = args
            }
            if let env = env {
                jsonConfig["env"] = env
            }
        } else {
            return nil
        }
        
        // Convert to JSON string without escaping slashes
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonConfig, options: [.withoutEscapingSlashes]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }
        
        // Build command
        var cmdParts = ["claude", "mcp", "add-json"]
        
        // Add scope if not project (default)
        if scope != .project {
            cmdParts.append("-s")
            cmdParts.append(scope.rawValue)
        }
        
        // Add name and JSON
        cmdParts.append("\"\(name)\"")
        cmdParts.append("'\(jsonString)'")
        
        return cmdParts.joined(separator: " ")
    }
}

// MARK: - Codable Support
extension MCPServer {
    static func isManagedSchedulerServer(_ name: String) -> Bool {
        return name == managedSchedulerServerName
    }

    static func isManagedAvatarServer(_ name: String) -> Bool {
        return name == managedAvatarServerName
    }

    static func isManagedServer(_ name: String) -> Bool {
        isManagedSchedulerServer(name) || isManagedAvatarServer(name)
    }

    /// Configuration structure matching .mcp.json format
    struct Configuration: Codable {
        // Local server properties
        var command: String?
        var args: [String]?
        var env: [String: String]?
        
        // Remote server properties
        var url: String?
        var headers: [String: String]?
    }
    
    /// Create server from configuration
    init(name: String, configuration: Configuration) {
        self.name = name
        self.command = configuration.command
        self.args = configuration.args
        self.env = configuration.env
        self.url = configuration.url
        self.headers = configuration.headers
    }
    
    /// Convert to configuration for saving
    var configuration: Configuration {
        Configuration(
            command: command,
            args: args,
            env: env,
            url: url,
            headers: headers
        )
    }
}
