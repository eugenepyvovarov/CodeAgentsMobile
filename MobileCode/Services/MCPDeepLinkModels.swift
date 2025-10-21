//
//  MCPDeepLinkModels.swift
//  CodeAgentsMobile
//
//  Created by Code Agent on 2025-02-15.
//

import Foundation

/// Payload for a single MCP server shared via deep link.
/// Supports both flat definitions and nested `config` blocks similar to `.mcp.json` files.
struct DeepLinkServerPayload: Codable, Equatable {
    let name: String
    let type: String?
    let command: String?
    let args: [String]?
    let env: [String: String]?
    let url: String?
    let headers: [String: String]?
    private let scopeRaw: String?

    /// Optional user-facing description included in some payload formats.
    let summary: String?

    init(
        name: String,
        type: String? = nil,
        command: String? = nil,
        args: [String]? = nil,
        env: [String: String]? = nil,
        url: String? = nil,
        headers: [String: String]? = nil,
        scope: MCPServer.MCPScope = .project,
        summary: String? = nil
    ) {
        self.name = name
        self.type = type
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.scopeRaw = scope.rawValue
        self.summary = summary
    }

    enum CodingKeys: String, CodingKey {
        case name
        case serverName
        case type
        case command
        case args
        case env
        case environment
        case url
        case headers
        case scope
        case config
        case summary
        case description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let directName = try container.decodeIfPresent(String.self, forKey: .name) {
            name = directName
        } else if let altName = try container.decodeIfPresent(String.self, forKey: .serverName) {
            name = altName
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.name,
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "Server name missing in deep link payload")
            )
        }

        type = try container.decodeIfPresent(String.self, forKey: .type)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? container.decodeIfPresent(String.self, forKey: .description)

        // Decode scope if present
        scopeRaw = try container.decodeIfPresent(String.self, forKey: .scope)

        // Helper to decode command-related fields either at top level or inside a `config` object.
        func decodeCommand(from container: KeyedDecodingContainer<CodingKeys>) throws -> (String?, [String]?, [String: String]?, String?, [String: String]?) {
            let command = try container.decodeIfPresent(String.self, forKey: .command)

            // Args may be encoded either as array of strings or a single string.
            var args: [String]? = try container.decodeIfPresent([String].self, forKey: .args)
            if args == nil, let argsString = try container.decodeIfPresent(String.self, forKey: .args) {
                args = argsString.split(separator: " ").map { String($0) }
            }

            let env = try container.decodeIfPresent([String: String].self, forKey: .env)
                ?? container.decodeIfPresent([String: String].self, forKey: .environment)
            let url = try container.decodeIfPresent(String.self, forKey: .url)
            let headers = try container.decodeIfPresent([String: String].self, forKey: .headers)

            return (command, args, env, url, headers)
        }

        if container.contains(.config) {
            let nested = try container.nestedContainer(keyedBy: CodingKeys.self, forKey: .config)
            let values = try decodeCommand(from: nested)
            command = values.0
            args = values.1
            env = values.2
            url = values.3
            headers = values.4
        } else {
            let values = try decodeCommand(from: container)
            command = values.0
            args = values.1
            env = values.2
            url = values.3
            headers = values.4
        }
    }

    /// Preferred scope requested by the payload (defaults to project scope).
    var scope: MCPServer.MCPScope {
        guard let scopeRaw else { return .project }
        return MCPServer.MCPScope(rawValue: scopeRaw.lowercased()) ?? .project
    }

    /// Determine whether this payload represents a remote server.
    var isRemote: Bool {
        if let url = url, !url.isEmpty { return true }
        guard let type else { return false }
        let lowered = type.lowercased()
        return lowered == "http" || lowered == "sse"
    }

    /// Create an `MCPServer` from the payload, optionally overriding the name.
    func makeServer(named overrideName: String? = nil) throws -> MCPServer {
        let trimmedName = (overrideName ?? name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw DeepLinkImportError.invalidServer("Server name cannot be empty")
        }

        if isRemote {
            guard let url = url, !url.isEmpty else {
                throw DeepLinkImportError.invalidServer("Remote MCP server \(name) is missing a URL")
            }

            let resolvedType: String
            if let providedType = type?.trimmingCharacters(in: .whitespacesAndNewlines), !providedType.isEmpty {
                resolvedType = providedType.lowercased()
            } else if url.lowercased().contains("sse") {
                resolvedType = "sse"
            } else {
                resolvedType = "http"
            }

            return MCPServer(
                name: trimmedName,
                command: nil,
                args: nil,
                env: nil,
                url: url,
                headers: headers,
                type: resolvedType
            )
        }

        guard let command = command, !command.isEmpty else {
            throw DeepLinkImportError.invalidServer("Local MCP server \(name) is missing a command")
        }

        let resolvedType = type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return MCPServer(
            name: trimmedName,
            command: command,
            args: args,
            env: env,
            url: nil,
            headers: nil,
            type: (resolvedType?.isEmpty == false ? resolvedType : "stdio")
        )
    }
}

/// Payload describing a bundle of MCP servers shared via deep link.
struct DeepLinkBundlePayload: Codable, Equatable {
    let name: String
    let description: String?
    let servers: [DeepLinkServerPayload]

    init(name: String, description: String? = nil, servers: [DeepLinkServerPayload]) {
        self.name = name
        self.description = description
        self.servers = servers
    }

    enum CodingKeys: String, CodingKey {
        case name
        case bundleName
        case description
        case summary
        case servers
        case mcpServers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let directName = try container.decodeIfPresent(String.self, forKey: .name) {
            name = directName
        } else if let bundleName = try container.decodeIfPresent(String.self, forKey: .bundleName) {
            name = bundleName
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.name,
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "Bundle name missing in deep link payload")
            )
        }

        description = try container.decodeIfPresent(String.self, forKey: .description)
            ?? container.decodeIfPresent(String.self, forKey: .summary)

        if let array = try container.decodeIfPresent([DeepLinkServerPayload].self, forKey: .servers) {
            servers = array
        } else if let dict = try container.decodeIfPresent([String: MCPServer.Configuration].self, forKey: .servers) {
            servers = dict.map { key, value in
                DeepLinkServerPayload(
                    name: key,
                    command: value.command,
                    args: value.args,
                    env: value.env,
                    url: value.url,
                    headers: value.headers
                )
            }
        } else if let dict = try container.decodeIfPresent([String: MCPServer.Configuration].self, forKey: .mcpServers) {
            servers = dict.map { key, value in
                DeepLinkServerPayload(
                    name: key,
                    command: value.command,
                    args: value.args,
                    env: value.env,
                    url: value.url,
                    headers: value.headers
                )
            }
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.servers,
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "Bundle payload does not contain any servers")
            )
        }
    }
}

/// Combined payload produced by decoding an incoming deep link.
enum DeepLinkPayload: Equatable {
    case server(DeepLinkServerPayload)
    case bundle(DeepLinkBundlePayload)
}

/// General error produced while parsing a deep link URL.
struct DeepLinkError: LocalizedError, Identifiable, Equatable {
    let id = UUID()
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }

    static func == (lhs: DeepLinkError, rhs: DeepLinkError) -> Bool {
        lhs.message == rhs.message
    }
}

/// Errors thrown while importing servers from a deep link payload.
enum DeepLinkImportError: LocalizedError {
    case invalidServer(String)
    case emptyBundle
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidServer(let message):
            return message
        case .emptyBundle:
            return "The bundle does not contain any MCP servers."
        case .importFailed(let message):
            return message
        }
    }
}
