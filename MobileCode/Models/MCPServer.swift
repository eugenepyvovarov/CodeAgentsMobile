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

    /// Underlying transport type for the server (e.g. stdio, http, sse).
    /// When nil we infer the type based on the available configuration.
    var type: String?

    // Local server properties
    var command: String?
    var args: [String]?
    var env: [String: String]?
    
    // Remote server properties
    var url: String?
    var headers: [String: String]?

    // Runtime status (not persisted in .mcp.json)
    var status: MCPStatus = .unknown

    init(
        name: String,
        command: String?,
        args: [String]?,
        env: [String: String]?,
        url: String?,
        headers: [String: String]?,
        type: String? = nil
    ) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.type = type
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
    
    /// Server scope for claude mcp add command
    enum MCPScope: String, CaseIterable {
        case project = "project"  // Shared via .mcp.json (default)
        case local = "local"      // Private to this machine
        case global = "global"    // Available across all projects
        
        var displayName: String {
            switch self {
            case .project:
                return "Project (Shared)"
            case .local:
                return "Local (Private)"
            case .global:
                return "Global (All Projects)"
            }
        }
        
        var description: String {
            switch self {
            case .project:
                return "Saved in .mcp.json, shared with team"
            case .local:
                return "Only on this device"
            case .global:
                return "Available in all your projects"
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
        if let type = type?.lowercased(), type == "http" || type == "sse" {
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
            let serverType = normalizedRemoteType() ?? (url.lowercased().contains("sse") ? "sse" : "http")
            jsonConfig["type"] = serverType
            jsonConfig["url"] = url
            if let headers = headers {
                jsonConfig["headers"] = headers
            }
        } else if let command = command {
            // Local server
            jsonConfig["type"] = normalizedLocalType()
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

    private func normalizedRemoteType() -> String? {
        guard let type else { return nil }
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    private func normalizedLocalType() -> String {
        guard let type = type?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty else {
            return "stdio"
        }
        return type.lowercased()
    }
}

// MARK: - Codable Support
extension MCPServer {
    /// Configuration structure matching .mcp.json format
    struct Configuration: Codable {
        var type: String?
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
        self.type = configuration.type
        self.command = configuration.command
        self.args = configuration.args
        self.env = configuration.env
        self.url = configuration.url
        self.headers = configuration.headers
    }
    
    /// Convert to configuration for saving
    var configuration: Configuration {
        Configuration(
            type: type,
            command: command,
            args: args,
            env: env,
            url: url,
            headers: headers
        )
    }
}