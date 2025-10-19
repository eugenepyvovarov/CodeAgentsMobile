//
//  MCPDeepLinkImporter.swift
//  CodeAgentsMobile
//
//  Created by Code Agent on 2025-02-15.
//

import Foundation

protocol MCPServerManaging {
    func fetchServers(for project: RemoteProject) async throws -> [MCPServer]
    func addServer(_ server: MCPServer, scope: MCPServer.MCPScope, for project: RemoteProject) async throws
}

extension MCPService: MCPServerManaging {}

/// Summary of servers added when processing a deep link.
struct MCPDeepLinkImportSummary: Equatable {
    struct AddedServer: Equatable {
        let originalName: String
        let finalName: String
        let scope: MCPServer.MCPScope
    }

    let bundleName: String?
    let addedServers: [AddedServer]

    var renamedServers: [AddedServer] {
        addedServers.filter { $0.originalName.caseInsensitiveCompare($0.finalName) != .orderedSame }
    }

    var count: Int { addedServers.count }
}

/// Handles importing MCP servers from deep link payloads into a project.
@MainActor
struct MCPDeepLinkImporter {
    private let service: MCPServerManaging

    init(service: MCPServerManaging = MCPService.shared) {
        self.service = service
    }

    func importServer(_ payload: DeepLinkServerPayload, into project: RemoteProject) async throws -> MCPDeepLinkImportSummary {
        let summary = try await importServers([payload], bundleName: nil, into: project)
        return summary
    }

    func importBundle(_ payload: DeepLinkBundlePayload, into project: RemoteProject) async throws -> MCPDeepLinkImportSummary {
        guard !payload.servers.isEmpty else {
            throw DeepLinkImportError.emptyBundle
        }
        return try await importServers(payload.servers, bundleName: payload.name, into: project)
    }

    private func importServers(_ payloads: [DeepLinkServerPayload], bundleName: String?, into project: RemoteProject) async throws -> MCPDeepLinkImportSummary {
        let existingServers = try await service.fetchServers(for: project)
        var usedNames = Set(existingServers.map { $0.name.lowercased() })
        var added: [MCPDeepLinkImportSummary.AddedServer] = []

        for payload in payloads {
            let uniqueName = generateUniqueName(for: payload.name, usedNames: &usedNames)
            let server = try payload.makeServer(named: uniqueName)
            do {
                try await service.addServer(server, scope: payload.scope, for: project)
            } catch {
                throw DeepLinkImportError.importFailed("Failed to add server \(uniqueName): \(error.localizedDescription)")
            }

            added.append(.init(originalName: payload.name, finalName: uniqueName, scope: payload.scope))
        }

        return MCPDeepLinkImportSummary(bundleName: bundleName, addedServers: added)
    }

    private func generateUniqueName(for baseName: String, usedNames: inout Set<String>) -> String {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()

        guard !trimmed.isEmpty else {
            return UUID().uuidString
        }

        if !usedNames.contains(normalized) {
            usedNames.insert(normalized)
            return trimmed
        }

        var index = 2
        while true {
            let candidate = "\(trimmed)-\(index)"
            if !usedNames.contains(candidate.lowercased()) {
                usedNames.insert(candidate.lowercased())
                return candidate
            }
            index += 1
        }
    }
}
