//
//  MCPStatusParser.swift
//  CodeAgentsMobile
//
//  Purpose: Parse output from `claude mcp list` command
//  Extracts server names and connection statuses
//

import Foundation

/// Parser for claude mcp list command output
struct MCPStatusParser {
    
    /// Parse server info from claude mcp list output
    /// Example input:
    /// ```
    /// Checking MCP server health...
    ///
    /// firecrawl: npx -y firecrawl-mcp - ✓ Connected
    /// sqlite: uv --directory /path run server - ✓ Connected
    /// playwright: npx @playwright/mcp@latest - ✗ Disconnected
    /// ```
    struct ServerInfo {
        let name: String
        let command: String
        let status: MCPServer.MCPStatus
    }
    
    static func parseServerList(_ output: String) -> [ServerInfo] {
        var servers: [ServerInfo] = []
        
        // Split by lines and process each
        let lines = output.components(separatedBy: .newlines)
        
        for line in lines {
            // Skip empty lines and header
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.contains("Checking MCP server health") {
                continue
            }
            
            // Look for pattern: "name: command - status"
            if let colonIndex = line.firstIndex(of: ":"),
               let dashIndex = line.lastIndex(of: "-") {
                
                let serverName = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let commandPart = String(line[line.index(after: colonIndex)..<dashIndex]).trimmingCharacters(in: .whitespaces)
                let statusPart = String(line[line.index(after: dashIndex)...]).trimmingCharacters(in: .whitespaces)
                
                // Determine status
                let status: MCPServer.MCPStatus
                if statusPart.contains("✓") || statusPart.contains("Connected") {
                    status = .connected
                } else if statusPart.contains("✗") || statusPart.contains("Disconnected") || statusPart.contains("Failed") {
                    status = .disconnected
                } else {
                    status = .unknown
                }
                
                servers.append(ServerInfo(
                    name: serverName,
                    command: commandPart,
                    status: status
                ))
            }
        }
        
        return servers
    }
    
    /// Parse status output and return dictionary of server name to status
    static func parseStatuses(_ output: String) -> [String: MCPServer.MCPStatus] {
        let servers = parseServerList(output)
        return Dictionary(uniqueKeysWithValues: servers.map { ($0.name, $0.status) })
    }
    
    /// Parse a single server status line
    /// Returns (serverName, status) or nil if can't parse
    static func parseServerLine(_ line: String) -> (name: String, status: MCPServer.MCPStatus)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        
        // Skip empty lines
        guard !trimmed.isEmpty else { return nil }
        
        // Find the colon that separates name from command
        guard let colonIndex = trimmed.firstIndex(of: ":") else { return nil }
        
        let name = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
        let remainder = String(trimmed[trimmed.index(after: colonIndex)...])
        
        // Determine status
        let status: MCPServer.MCPStatus
        if remainder.contains("✓") || remainder.contains("Connected") {
            status = .connected
        } else if remainder.contains("✗") || remainder.contains("Disconnected") || remainder.contains("Failed") {
            status = .disconnected
        } else {
            status = .unknown
        }
        
        return (name, status)
    }
    
    /// Extract just the server names from the output
    static func parseServerNames(_ output: String) -> [String] {
        let statuses = parseStatuses(output)
        return Array(statuses.keys).sorted()
    }
    
    /// Check if the output indicates an error
    static func isErrorOutput(_ output: String) -> Bool {
        let lowercased = output.lowercased()
        return lowercased.contains("error") || 
               lowercased.contains("command not found") ||
               lowercased.contains("claude: command not found") ||
               lowercased.contains("permission denied")
    }
    
    /// Extract error message if present
    static func extractError(_ output: String) -> String? {
        if isErrorOutput(output) {
            // Return the first non-empty line that likely contains the error
            let lines = output.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && (trimmed.lowercased().contains("error") || 
                                       trimmed.contains("not found") ||
                                       trimmed.contains("denied")) {
                    return trimmed
                }
            }
            return "Unknown error occurred"
        }
        return nil
    }
    
    /// Parse detailed server information from claude mcp get output
    /// Example output:
    /// ```
    /// firecrawl:
    ///   Scope: Local config (private to you in this project)
    ///   Status: ✓ Connected
    ///   Type: stdio
    ///   Command: npx
    ///   Args: -y firecrawl-mcp
    ///   Environment:
    ///     FIRECRAWL_API_KEY=fc-44302501fff148dfb6c632fe0dacf644
    /// ```
    static func parseServerDetails(_ output: String) -> (server: MCPServer, scope: MCPServer.MCPScope)? {
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.isEmpty else { return nil }
        
        // Extract server name from first line (format: "servername:")
        guard let firstLine = lines.first,
              firstLine.hasSuffix(":"),
              !firstLine.isEmpty else { return nil }
        
        let serverName = String(firstLine.dropLast())
        
        // Parse remaining fields
        var scope: MCPServer.MCPScope = .project
        var status: MCPServer.MCPStatus = .unknown
        var type: String?
        var command: String?
        var args: [String] = []
        var env: [String: String] = [:]
        var url: String?
        var headers: [String: String] = [:]
        
        var isInEnvironment = false
        var isInHeaders = false
        
        for i in 1..<lines.count {
            let line = lines[i]
            guard !line.isEmpty else { continue }
            
            // Check for section headers
            if line.hasPrefix("Scope:") {
                let scopeText = line.replacingOccurrences(of: "Scope:", with: "").trimmingCharacters(in: .whitespaces)
                if scopeText.contains("Local config") {
                    scope = .local
                } else if scopeText.contains("Project config") {
                    scope = .project
                } else if scopeText.contains("User config") || scopeText.contains("global") {
                    scope = .global
                }
                isInEnvironment = false
                isInHeaders = false
            } else if line.hasPrefix("Status:") {
                let statusText = line.replacingOccurrences(of: "Status:", with: "").trimmingCharacters(in: .whitespaces)
                if statusText.contains("Connected") || statusText.contains("✓") {
                    status = .connected
                } else if statusText.contains("Disconnected") || statusText.contains("✗") {
                    status = .disconnected
                }
                isInEnvironment = false
                isInHeaders = false
            } else if line.hasPrefix("Type:") {
                type = line.replacingOccurrences(of: "Type:", with: "").trimmingCharacters(in: .whitespaces)
                isInEnvironment = false
                isInHeaders = false
            } else if line.hasPrefix("Command:") {
                command = line.replacingOccurrences(of: "Command:", with: "").trimmingCharacters(in: .whitespaces)
                isInEnvironment = false
                isInHeaders = false
            } else if line.hasPrefix("Args:") {
                let argsText = line.replacingOccurrences(of: "Args:", with: "").trimmingCharacters(in: .whitespaces)
                if !argsText.isEmpty {
                    // Handle single line args
                    args = argsText.components(separatedBy: " ")
                }
                isInEnvironment = false
                isInHeaders = false
            } else if line.hasPrefix("URL:") {
                url = line.replacingOccurrences(of: "URL:", with: "").trimmingCharacters(in: .whitespaces)
                isInEnvironment = false
                isInHeaders = false
            } else if line.hasPrefix("Environment:") {
                isInEnvironment = true
                isInHeaders = false
            } else if line.hasPrefix("Headers:") {
                isInEnvironment = false
                isInHeaders = true
            } else if line.hasPrefix("To remove") {
                // End of server details
                break
            } else if isInEnvironment {
                // Parse environment variable (format: KEY=value or KEY: value)
                if let equalRange = line.range(of: "=") {
                    let key = String(line[..<equalRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[equalRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    env[key] = value
                } else if let colonRange = line.range(of: ":") {
                    let key = String(line[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    env[key] = value
                }
            } else if isInHeaders {
                // Parse header (format: Header-Name: value)
                if let colonRange = line.range(of: ":") {
                    let key = String(line[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                }
            }
        }
        
        // Create MCPServer based on type
        let server: MCPServer
        if type == "stdio" {
            server = MCPServer(
                name: serverName,
                command: command,
                args: args.isEmpty ? nil : args,
                env: env.isEmpty ? nil : env,
                url: nil,
                headers: nil,
                type: type
            )
        } else {
            // Remote server (sse or http)
            server = MCPServer(
                name: serverName,
                command: nil,
                args: nil,
                env: nil,
                url: url,
                headers: headers.isEmpty ? nil : headers,
                type: type
            )
        }
        
        var mutableServer = server
        mutableServer.status = status
        
        return (mutableServer, scope)
    }
}