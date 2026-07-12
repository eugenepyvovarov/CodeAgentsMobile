//
//  ProxyAgentIdentityService.swift
//  CodeAgentsMobile
//
//  Purpose: Ensure a stable agent_id exists on the server
//  - Stored in <agent cwd>/.codeagents/codeagents.json
//  - Used to keep proxy tasks/env stable across app reinstalls
//  - Merge-safe: never wipe avatar when ensuring agent_id
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
        let existingDocument = parseDocument(from: identity.rawJSON)
        let serverAgentId = existingDocument?.agentId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        let resolvedAgentId: String
        if let serverAgentId {
            resolvedAgentId = serverAgentId
        } else {
            resolvedAgentId = fallbackAgentId
        }

        if identity.source != .primary || serverAgentId == nil {
            var document = existingDocument ?? CodeAgentsIdentityDocument(agentId: resolvedAgentId)
            document.agentId = resolvedAgentId
            if document.schemaVersion < CodeAgentsIdentityDocument.currentSchemaVersion {
                document.schemaVersion = CodeAgentsIdentityDocument.currentSchemaVersion
            }
            try await writeIdentityDocument(document, at: identityPath, session: session)
        }

        if project.proxyAgentId != resolvedAgentId {
            project.proxyAgentId = resolvedAgentId
            try modelContext.save()
        }

        // Best-effort avatar cache refresh when we already have identity content.
        if let document = existingDocument ?? parseDocument(from: identity.rawJSON) {
            AgentAvatarService.applyCacheMetadata(document.avatar, to: project)
        }

        return resolvedAgentId
    }

    /// Read identity document (primary, then legacy). Returns nil when missing/unreadable.
    func readIdentityDocument(
        for project: RemoteProject,
        session: SSHSession
    ) async -> CodeAgentsIdentityDocument? {
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
        return parseDocument(from: identity.rawJSON)
    }

    /// Merge-write identity document (preserves unspecified fields already on disk).
    func writeIdentityDocument(
        _ document: CodeAgentsIdentityDocument,
        for project: RemoteProject,
        session: SSHSession
    ) async throws {
        let identityPath = AgentProjectFileLayout.remotePath(
            projectPath: project.path,
            relativePath: AgentProjectFileLayout.identityRelativePath
        )
        try await writeIdentityDocument(document, at: identityPath, session: session)
    }

    /// Load on-disk document, apply transform, write back.
    func updateIdentityDocument(
        for project: RemoteProject,
        session: SSHSession,
        transform: (inout CodeAgentsIdentityDocument) -> Void
    ) async throws -> CodeAgentsIdentityDocument {
        let existing = await readIdentityDocument(for: project, session: session)
        var document = existing ?? CodeAgentsIdentityDocument(
            agentId: ProxyTaskService.resolvedAgentId(for: project)
        )
        if document.agentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            document.agentId = ProxyTaskService.resolvedAgentId(for: project)
        }
        transform(&document)
        if document.schemaVersion < CodeAgentsIdentityDocument.currentSchemaVersion {
            document.schemaVersion = CodeAgentsIdentityDocument.currentSchemaVersion
        }
        try await writeIdentityDocument(document, for: project, session: session)
        return document
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

    private func parseDocument(from rawJSON: String) -> CodeAgentsIdentityDocument? {
        let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? CodeAgentsIdentityDocument.decode(from: data)
    }

    private func writeIdentityDocument(
        _ document: CodeAgentsIdentityDocument,
        at remotePath: String,
        session: SSHSession
    ) async throws {
        let dir = (remotePath as NSString).deletingLastPathComponent
        let data = try document.encodeJSON()
        let base64 = data.base64EncodedString()

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

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
