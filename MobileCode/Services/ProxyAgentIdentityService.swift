//
//  ProxyAgentIdentityService.swift
//  CodeAgentsMobile
//
//  Purpose: Ensure a stable agent_id exists on the server
//  - Stored in <agent cwd>/.codeagents/codeagents.json
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
        // Prefer a fresh file-ops session — pooled channels can hang on execute after long idle.
        sshService.closeConnections(projectId: project.id, purpose: .fileOperations)
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        let identityPath = AgentProjectFileLayout.remotePath(
            projectPath: project.path,
            relativePath: AgentProjectFileLayout.identityRelativePath
        )
        let legacyIdentityPath = AgentProjectFileLayout.remotePath(
            projectPath: project.path,
            relativePath: AgentProjectFileLayout.legacyIdentityRelativePath
        )

        let identity = await readIdentityFile(
            primaryPath: identityPath,
            legacyPath: legacyIdentityPath,
            session: session
        )

        // Match ProxyTaskService / MCP scheduler headers (lowercased UUID fallback).
        let fallbackAgentId = ProxyTaskService.resolvedAgentId(for: project)
        let serverAgentId = parseAgentId(from: identity.rawJSON)

        let resolvedAgentId: String
        if let serverAgentId {
            resolvedAgentId = serverAgentId
        } else {
            resolvedAgentId = fallbackAgentId
        }

        if identity.source != .primary || serverAgentId == nil {
            try await writeIdentityFile(agentId: resolvedAgentId, at: identityPath, session: session)
        }

        if project.proxyAgentId != resolvedAgentId {
            project.proxyAgentId = resolvedAgentId
            try modelContext.save()
        }

        return resolvedAgentId
    }

    private func readIdentityFile(
        primaryPath: String,
        legacyPath: String,
        session: SSHSession
    ) async -> (source: IdentitySource, rawJSON: String) {
        let markerToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let markerStart = "__CODEAGENTS_IDENTITY_START_\(markerToken)__"
        let markerEnd = "__CODEAGENTS_IDENTITY_END_\(markerToken)__"
        let primaryEscaped = shellEscaped(primaryPath)
        let legacyEscaped = shellEscaped(legacyPath)
        let command = [
            "printf \(shellEscaped(markerStart));",
            "if [ -f \(primaryEscaped) ]; then",
            "printf \(shellEscaped("SOURCE:\(IdentitySource.primary.rawValue):"));",
            "(base64 -w 0 \(primaryEscaped) 2>/dev/null || base64 \(primaryEscaped));",
            "elif [ -f \(legacyEscaped) ]; then",
            "printf \(shellEscaped("SOURCE:\(IdentitySource.legacy.rawValue):"));",
            "(base64 -w 0 \(legacyEscaped) 2>/dev/null || base64 \(legacyEscaped));",
            "else",
            "printf \(shellEscaped("MISSING"));",
            "fi;",
            "printf \(shellEscaped(markerEnd))"
        ].joined(separator: " ")

        guard let output = try? await session.execute(command),
              let startRange = output.range(of: markerStart),
              let endRange = output.range(of: markerEnd),
              startRange.upperBound <= endRange.lowerBound else {
            return (.missing, "")
        }

        let payload = String(output[startRange.upperBound..<endRange.lowerBound])
        guard payload != "MISSING" else {
            return (.missing, "")
        }
        let prefix = "SOURCE:"
        guard payload.hasPrefix(prefix) else {
            return (.missing, "")
        }

        let remainder = String(payload.dropFirst(prefix.count))
        guard let separator = remainder.firstIndex(of: ":"),
              let source = IdentitySource(rawValue: String(remainder[..<separator])) else {
            return (.missing, "")
        }

        let base64Start = remainder.index(after: separator)
        let base64Payload = String(remainder[base64Start...])
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let data = Data(base64Encoded: base64Payload),
              let json = String(data: data, encoding: .utf8) else {
            return (source, "")
        }

        return (source, json)
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
        mkdir -p \(shellEscaped(dir)) && echo \(shellEscaped(base64)) | (base64 -d 2>/dev/null || base64 --decode) > \(shellEscaped(remotePath))
        """
        _ = try await session.execute(writeCommand)
    }

    private func shellEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}

extension ProxyAgentIdentityService {
    func ensureAgentId(for project: RemoteProject, modelContext: ModelContext) async throws -> String {
        try await ensureProxyAgentId(for: project, modelContext: modelContext)
    }
}

typealias AgentIdentityService = ProxyAgentIdentityService

private enum IdentitySource: String {
    case primary
    case legacy
    case missing
}

private struct CodeAgentsIdentityFile: Codable {
    let schemaVersion: Int
    let agentId: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case agentId = "agent_id"
    }
}
