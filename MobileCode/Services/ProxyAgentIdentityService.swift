//
//  ProxyAgentIdentityService.swift
//  CodeAgentsMobile
//
//  Purpose: Ensure a stable proxy agent_id exists on the server
//  - Stored in <agent cwd>/.claude/codeagents.json
//  - Used to keep proxy tasks/env stable across app reinstalls
//

import Foundation
import SwiftData

@MainActor
final class ProxyAgentIdentityService {
    static let shared = ProxyAgentIdentityService()

    private let sshService = SSHService.shared

    private init() {}

    func ensureProxyAgentId(for project: RemoteProject, modelContext: ModelContext) async throws -> String {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        let identityPath = "\(project.path)/.claude/codeagents.json"

        let readCommand = """
        if [ -f "\(identityPath)" ]; then
            cat "\(identityPath)"
        fi
        """
        let raw = (try? await session.execute(readCommand))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let fallbackAgentId = project.proxyAgentId ?? project.id.uuidString
        let serverAgentId = parseAgentId(from: raw)

        let resolvedAgentId: String
        if let serverAgentId {
            resolvedAgentId = serverAgentId
        } else {
            resolvedAgentId = fallbackAgentId
            try await writeIdentityFile(agentId: resolvedAgentId, at: identityPath, session: session)
        }

        if project.proxyAgentId != resolvedAgentId {
            project.proxyAgentId = resolvedAgentId
            try modelContext.save()
        }

        return resolvedAgentId
    }

    private func parseAgentId(from rawJSON: String) -> String? {
        let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }

        do {
            let decoded = try JSONDecoder().decode(CodeAgentsIdentityFile.self, from: data)
            let agentId = decoded.agentId.trimmingCharacters(in: .whitespacesAndNewlines)
            return agentId.isEmpty ? nil : agentId
        } catch {
            return nil
        }
    }

    private func writeIdentityFile(agentId: String, at remotePath: String, session: SSHSession) async throws {
        let dir = (remotePath as NSString).deletingLastPathComponent
        let payload = CodeAgentsIdentityFile(schemaVersion: 1, agentId: agentId)
        let data = try JSONEncoder().encode(payload)

        let json = (String(data: data, encoding: .utf8) ?? "{}") + "\n"
        let base64 = Data(json.utf8).base64EncodedString()

        let writeCommand = """
        mkdir -p "\(dir)" && echo '\(base64)' | (base64 -d 2>/dev/null || base64 --decode) > "\(remotePath)"
        """
        _ = try await session.execute(writeCommand)
    }
}

private struct CodeAgentsIdentityFile: Codable {
    let schemaVersion: Int
    let agentId: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case agentId = "agent_id"
    }
}
