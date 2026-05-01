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

/// Root structure of OpenCode's opencode.json/opencode.jsonc MCP configuration.
struct OpenCodeMCPConfiguration: Codable, Equatable {
    var schema: String?
    var mcp: [String: OpenCodeMCPServerConfiguration]

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case mcp
    }

    init(schema: String? = "https://opencode.ai/config.json", mcp: [String: OpenCodeMCPServerConfiguration] = [:]) {
        self.schema = schema
        self.mcp = mcp
    }

    init(servers: [MCPServer]) {
        self.schema = "https://opencode.ai/config.json"
        self.mcp = Dictionary(
            uniqueKeysWithValues: servers.compactMap { server in
                guard let configuration = OpenCodeMCPServerConfiguration(server: server) else {
                    return nil
                }
                return (server.name, configuration)
            }
        )
    }

    var servers: [MCPServer] {
        mcp.compactMap { name, configuration in
            MCPServer(name: name, openCodeConfiguration: configuration)
        }
    }

    mutating func setServer(_ server: MCPServer) throws {
        guard let configuration = OpenCodeMCPServerConfiguration(server: server) else {
            throw MCPConfigurationError.encodingFailed
        }
        mcp[server.name] = configuration
    }

    mutating func removeServer(named name: String) {
        mcp.removeValue(forKey: name)
    }
}

struct OpenCodeMCPServerConfiguration: Codable, Equatable {
    enum ServerType: String, Codable {
        case local
        case remote
    }

    var type: ServerType
    var command: [String]?
    var environment: [String: String]?
    var enabled: Bool?
    var timeout: Int?
    var url: String?
    var headers: [String: String]?

    init(
        type: ServerType,
        command: [String]? = nil,
        environment: [String: String]? = nil,
        enabled: Bool? = true,
        timeout: Int? = nil,
        url: String? = nil,
        headers: [String: String]? = nil
    ) {
        self.type = type
        self.command = command
        self.environment = environment
        self.enabled = enabled
        self.timeout = timeout
        self.url = url
        self.headers = headers
    }

    init?(server: MCPServer, enabled: Bool = true) {
        if let url = server.url, !url.isEmpty {
            self.init(
                type: .remote,
                enabled: enabled,
                url: url,
                headers: server.headers?.nilIfEmpty
            )
            return
        }

        guard let command = server.command, !command.isEmpty else {
            return nil
        }

        self.init(
            type: .local,
            command: [command] + (server.args ?? []),
            environment: server.env?.nilIfEmpty,
            enabled: enabled
        )
    }
}

extension MCPServer {
    init?(name: String, openCodeConfiguration: OpenCodeMCPServerConfiguration) {
        switch openCodeConfiguration.type {
        case .local:
            guard let commandParts = openCodeConfiguration.command,
                  let command = commandParts.first,
                  !command.isEmpty else {
                return nil
            }
            self.init(
                name: name,
                command: command,
                args: Array(commandParts.dropFirst()).nilIfEmpty,
                env: openCodeConfiguration.environment?.nilIfEmpty,
                url: nil,
                headers: nil,
                status: openCodeConfiguration.enabled == false ? .disconnected : .unknown
            )
        case .remote:
            guard let url = openCodeConfiguration.url, !url.isEmpty else {
                return nil
            }
            self.init(
                name: name,
                command: nil,
                args: nil,
                env: nil,
                url: url,
                headers: openCodeConfiguration.headers?.nilIfEmpty,
                status: openCodeConfiguration.enabled == false ? .disconnected : .unknown
            )
        }
    }
}

enum OpenCodeJSONC {
    static func normalize(_ input: String) -> String {
        removeTrailingCommas(from: stripComments(from: input))
    }

    static func stripComments(from input: String) -> String {
        let bytes = Array(input.utf8)
        var output: [UInt8] = []
        var index = 0
        var inString = false
        var escaped = false

        while index < bytes.count {
            let byte = bytes[index]

            if inString {
                output.append(byte)
                if escaped {
                    escaped = false
                } else if byte == 0x5c {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                index += 1
                continue
            }

            if byte == 0x22 {
                inString = true
                output.append(byte)
                index += 1
                continue
            }

            if byte == 0x2f, index + 1 < bytes.count {
                let next = bytes[index + 1]

                if next == 0x2f {
                    index += 2
                    while index < bytes.count, bytes[index] != 0x0a, bytes[index] != 0x0d {
                        index += 1
                    }
                    continue
                }

                if next == 0x2a {
                    index += 2
                    while index + 1 < bytes.count, !(bytes[index] == 0x2a && bytes[index + 1] == 0x2f) {
                        if bytes[index] == 0x0a || bytes[index] == 0x0d {
                            output.append(bytes[index])
                        }
                        index += 1
                    }
                    index = min(index + 2, bytes.count)
                    continue
                }
            }

            output.append(byte)
            index += 1
        }

        return String(decoding: output, as: UTF8.self)
    }

    private static func removeTrailingCommas(from input: String) -> String {
        let bytes = Array(input.utf8)
        var output: [UInt8] = []
        var index = 0
        var inString = false
        var escaped = false

        while index < bytes.count {
            let byte = bytes[index]

            if inString {
                output.append(byte)
                if escaped {
                    escaped = false
                } else if byte == 0x5c {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                index += 1
                continue
            }

            if byte == 0x22 {
                inString = true
                output.append(byte)
                index += 1
                continue
            }

            if byte == 0x2c {
                var lookahead = index + 1
                while lookahead < bytes.count,
                      bytes[lookahead] == 0x20 || bytes[lookahead] == 0x09 ||
                      bytes[lookahead] == 0x0a || bytes[lookahead] == 0x0d {
                    lookahead += 1
                }

                if lookahead < bytes.count, bytes[lookahead] == 0x7d || bytes[lookahead] == 0x5d {
                    index += 1
                    continue
                }
            }

            output.append(byte)
            index += 1
        }

        return String(decoding: output, as: UTF8.self)
    }
}

struct OpenCodeMCPConfigDocument {
    private(set) var root: [String: Any]

    init(root: [String: Any] = [:]) {
        self.root = root
    }

    init(jsonString: String) throws {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.root = [:]
            return
        }

        guard let data = OpenCodeJSONC.normalize(trimmed).data(using: .utf8) else {
            throw MCPConfigurationError.invalidJSON
        }

        let decoded = try JSONSerialization.jsonObject(with: data, options: [])
        guard let root = decoded as? [String: Any] else {
            throw MCPConfigurationError.invalidJSON
        }
        self.root = root
    }

    var servers: [MCPServer] {
        serverConfigurations().compactMap { name, configuration in
            MCPServer(name: name, openCodeConfiguration: configuration)
        }
    }

    func server(named name: String) -> MCPServer? {
        guard let configuration = serverConfigurations()[name] else {
            return nil
        }
        return MCPServer(name: name, openCodeConfiguration: configuration)
    }

    func serverConfigurations() -> [String: OpenCodeMCPServerConfiguration] {
        guard let rawServers = root["mcp"] as? [String: Any] else {
            return [:]
        }

        return rawServers.reduce(into: [:]) { partialResult, item in
            guard JSONSerialization.isValidJSONObject(item.value),
                  let data = try? JSONSerialization.data(withJSONObject: item.value, options: []),
                  let configuration = try? JSONDecoder().decode(OpenCodeMCPServerConfiguration.self, from: data) else {
                return
            }
            partialResult[item.key] = configuration
        }
    }

    mutating func setServer(_ server: MCPServer) throws {
        guard let configuration = OpenCodeMCPServerConfiguration(server: server) else {
            throw MCPConfigurationError.encodingFailed
        }
        try setServer(named: server.name, configuration: configuration)
    }

    mutating func setServer(named name: String, configuration: OpenCodeMCPServerConfiguration) throws {
        let data = try JSONEncoder().encode(configuration)
        guard let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw MCPConfigurationError.encodingFailed
        }

        if root["$schema"] == nil {
            root["$schema"] = "https://opencode.ai/config.json"
        }

        var rawServers = root["mcp"] as? [String: Any] ?? [:]
        rawServers[name] = object
        root["mcp"] = rawServers
    }

    mutating func removeServer(named name: String) {
        var rawServers = root["mcp"] as? [String: Any] ?? [:]
        rawServers.removeValue(forKey: name)
        root["mcp"] = rawServers
    }

    func toJSONString() throws -> String {
        guard JSONSerialization.isValidJSONObject(root) else {
            throw MCPConfigurationError.encodingFailed
        }

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard let string = String(data: data, encoding: .utf8) else {
            throw MCPConfigurationError.encodingFailed
        }
        return string + "\n"
    }
}

private extension Dictionary {
    var nilIfEmpty: Dictionary? {
        isEmpty ? nil : self
    }
}

private extension Array {
    var nilIfEmpty: Array? {
        isEmpty ? nil : self
    }
}
