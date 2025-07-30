//
//  MCPConfiguration.swift
//  CodeAgentsMobile
//
//  Purpose: Model for .mcp.json file structure
//  Handles parsing and serialization of MCP server configurations
//

import Foundation

/// Root structure of .mcp.json file
struct MCPConfiguration: Codable {
    var mcpServers: [String: MCPServer.Configuration]
    
    /// Create empty configuration
    init() {
        self.mcpServers = [:]
    }
    
    /// Create configuration from servers
    init(servers: [MCPServer]) {
        self.mcpServers = Dictionary(
            uniqueKeysWithValues: servers.map { ($0.name, $0.configuration) }
        )
    }
    
    /// Convert to array of MCPServer objects
    var servers: [MCPServer] {
        mcpServers.map { MCPServer(name: $0.key, configuration: $0.value) }
    }
    
    /// Add or update a server
    mutating func setServer(_ server: MCPServer) {
        mcpServers[server.name] = server.configuration
    }
    
    /// Remove a server
    mutating func removeServer(named name: String) {
        mcpServers.removeValue(forKey: name)
    }
    
    /// Check if a server exists
    func hasServer(named name: String) -> Bool {
        mcpServers[name] != nil
    }
    
    /// Get a specific server
    func server(named name: String) -> MCPServer? {
        guard let config = mcpServers[name] else { return nil }
        return MCPServer(name: name, configuration: config)
    }
}

// MARK: - JSON Serialization
extension MCPConfiguration {
    /// Load configuration from JSON data
    static func load(from data: Data) throws -> MCPConfiguration {
        let decoder = JSONDecoder()
        return try decoder.decode(MCPConfiguration.self, from: data)
    }
    
    /// Load configuration from JSON string
    static func load(from jsonString: String) throws -> MCPConfiguration {
        guard let data = jsonString.data(using: .utf8) else {
            throw MCPConfigurationError.invalidJSON
        }
        return try load(from: data)
    }
    
    /// Convert to JSON data
    func toJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
    
    /// Convert to JSON string
    func toJSONString() throws -> String {
        let data = try toJSON()
        guard let string = String(data: data, encoding: .utf8) else {
            throw MCPConfigurationError.encodingFailed
        }
        return string
    }
}

// MARK: - Error Types
enum MCPConfigurationError: LocalizedError {
    case invalidJSON
    case encodingFailed
    case fileNotFound
    
    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Invalid JSON format"
        case .encodingFailed:
            return "Failed to encode configuration"
        case .fileNotFound:
            return ".mcp.json file not found"
        }
    }
}