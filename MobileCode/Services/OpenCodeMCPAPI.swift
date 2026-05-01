//
//  OpenCodeMCPAPI.swift
//  CodeAgentsMobile
//
//  Purpose: Typed OpenCode MCP endpoints
//

import Foundation

extension OpenCodeClient {
    func mcpStatus(
        sshSession: SSHSession,
        directory: String? = nil
    ) async throws -> [String: OpenCodeMCPStatus] {
        try await jsonRequest(
            session: sshSession,
            method: .get,
            path: OpenCodeSessionPath.path("/mcp", directory: directory),
            responseType: [String: OpenCodeMCPStatus].self
        )
    }

    func addMCPServer(
        sshSession: SSHSession,
        name: String,
        config: OpenCodeMCPServerConfiguration,
        directory: String? = nil
    ) async throws -> [String: OpenCodeMCPStatus] {
        try await jsonRequest(
            session: sshSession,
            method: .post,
            path: OpenCodeSessionPath.path("/mcp", directory: directory),
            body: OpenCodeSessionJSON.encode(OpenCodeMCPAddPayload(name: name, config: config)),
            responseType: [String: OpenCodeMCPStatus].self
        )
    }

    func connectMCPServer(
        sshSession: SSHSession,
        name: String,
        directory: String? = nil
    ) async throws -> Bool {
        try await jsonRequest(
            session: sshSession,
            method: .post,
            path: OpenCodeSessionPath.path("/mcp/\(OpenCodeSessionPath.escape(name))/connect", directory: directory),
            responseType: Bool.self
        )
    }

    func disconnectMCPServer(
        sshSession: SSHSession,
        name: String,
        directory: String? = nil
    ) async throws -> Bool {
        try await jsonRequest(
            session: sshSession,
            method: .post,
            path: OpenCodeSessionPath.path("/mcp/\(OpenCodeSessionPath.escape(name))/disconnect", directory: directory),
            responseType: Bool.self
        )
    }
}

struct OpenCodeMCPStatus: Decodable, Equatable {
    let status: String
    let error: String?

    var mcpStatus: MCPServer.MCPStatus {
        switch status.lowercased() {
        case "connected":
            return .connected
        case "disabled", "failed", "needs_auth", "needs_client_registration":
            return .disconnected
        default:
            return .unknown
        }
    }
}

private struct OpenCodeMCPAddPayload: Encodable {
    let name: String
    let config: OpenCodeMCPServerConfiguration
}
