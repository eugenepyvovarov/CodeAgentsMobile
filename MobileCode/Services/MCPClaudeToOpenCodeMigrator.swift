//
//  MCPClaudeToOpenCodeMigrator.swift
//  CodeAgentsMobile
//
//  Purpose: Pure conversion / merge helpers for Claude MCP → OpenCode config (Path D)
//

import Foundation

/// Result of importing Claude-side MCP definitions into an OpenCode config document.
struct MCPMigrationReport: Equatable {
    var imported: [String] = []
    var skippedExisting: [String] = []
    var skippedManaged: [String] = []
    var failed: [(name: String, reason: String)] = []
    /// Machine-readable note (e.g. `no_claude_mcp_source`). Never secrets.
    var note: String?

    var didImport: Bool { !imported.isEmpty }

    var failedNames: [String] {
        failed.map(\.name)
    }

    static func == (lhs: MCPMigrationReport, rhs: MCPMigrationReport) -> Bool {
        lhs.imported == rhs.imported
            && lhs.skippedExisting == rhs.skippedExisting
            && lhs.skippedManaged == rhs.skippedManaged
            && lhs.failedNames == rhs.failedNames
            && lhs.failed.map(\.reason) == rhs.failed.map(\.reason)
            && lhs.note == rhs.note
    }
}

enum MCPClaudeToOpenCodeMigrator {
    /// Parse Claude `.mcp.json` content into shared server models.
    static func servers(fromClaudeMCPJSON jsonString: String) throws -> [MCPServer] {
        let configuration = try MCPConfiguration.load(from: jsonString)
        return configuration.servers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Whether a Claude MCP server can be expressed as OpenCode local/remote config.
    static func isImportable(_ server: MCPServer) -> Bool {
        if MCPServer.isManagedSchedulerServer(server.name) {
            return false
        }
        return OpenCodeMCPServerConfiguration(server: server.normalizedForOpenCodeImport()) != nil
    }

    /// Merge Claude servers into an existing OpenCode document without overwriting existing names.
    /// - Returns: updated document + report (names only).
    static func merge(
        servers: [MCPServer],
        into document: OpenCodeMCPConfigDocument
    ) -> (document: OpenCodeMCPConfigDocument, report: MCPMigrationReport) {
        var document = document
        var report = MCPMigrationReport()
        let existingNames = Set(document.serverConfigurations().keys)

        for server in servers {
            let name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                report.failed.append((name: server.name, reason: "empty_name"))
                continue
            }

            if MCPServer.isManagedSchedulerServer(name) {
                report.skippedManaged.append(name)
                continue
            }

            if existingNames.contains(name) || report.imported.contains(name) {
                report.skippedExisting.append(name)
                continue
            }

            let normalized = server.normalizedForOpenCodeImport()
            guard let configuration = OpenCodeMCPServerConfiguration(server: normalized) else {
                report.failed.append((name: name, reason: "unconvertible"))
                continue
            }

            do {
                try document.setServer(named: name, configuration: configuration)
                report.imported.append(name)
            } catch {
                report.failed.append((name: name, reason: "encode_failed"))
            }
        }

        return (document, report)
    }
}

extension MCPServer {
    /// Normalize Claude CLI / `.mcp.json` quirks into OpenCode-importable shape.
    /// - Remote servers listed as command `http`/`sse` with a URL in args become remote URL servers.
    func normalizedForOpenCodeImport() -> MCPServer {
        var copy = self

        if let url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.command = nil
            copy.args = nil
            return copy
        }

        let commandValue = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if commandValue.lowercased() == "http" || commandValue.lowercased() == "sse" {
            if let firstArg = args?.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                copy.url = firstArg
                copy.command = nil
                copy.args = nil
                return copy
            }
        }

        return copy
    }
}
