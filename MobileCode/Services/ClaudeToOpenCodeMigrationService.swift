//
//  ClaudeToOpenCodeMigrationService.swift
//  CodeAgentsMobile
//
//  Purpose: Per-project orchestrator for Claude Proxy → OpenCode migration
//

import Foundation
import SwiftData

/// Non-isolated migration schema constants (safe to reference from model init / tests).
enum ClaudeToOpenCodeMigration {
    /// Bump when migration steps change incompatibly; stored on `RemoteProject.openCodeMigrationVersion`.
    static let currentVersion = 1
}

/// Coordinates runtime promote, optional credential assist, Path D MCP import, and session bootstrap.
@MainActor
final class ClaudeToOpenCodeMigrationService {
    static let shared = ClaudeToOpenCodeMigrationService()

    /// Convenience alias for `ClaudeToOpenCodeMigration.currentVersion`.
    static var currentMigrationVersion: Int { ClaudeToOpenCodeMigration.currentVersion }

    private let mcpService: CodingAgentMCPService
    private let openCodeRuntime: OpenCodeRuntimeService
    private let keychain: KeychainManager
    private let sshService: SSHService
    private let credentialProviderIDs = ["anthropic", "zai", "minimax", "moonshot"]

    init(
        mcpService: CodingAgentMCPService? = nil,
        openCodeRuntime: OpenCodeRuntimeService? = nil,
        keychain: KeychainManager = .shared,
        sshService: SSHService? = nil
    ) {
        self.mcpService = mcpService ?? .shared
        self.openCodeRuntime = openCodeRuntime ?? OpenCodeRuntimeService()
        self.keychain = keychain
        self.sshService = sshService ?? ServiceManager.shared.sshService
    }

    struct MigrationReport: Equatable {
        var didMigrate: Bool = false
        var alreadyMigrated: Bool = false
        var promotedRuntime: Bool = false
        var clearedProxyTransport: Bool = false
        var credentialProvidersCopied: [String] = []
        var mcp: MCPMigrationReport = MCPMigrationReport()
        var rulesCopiedFrom: String?
        var ensuredSession: Bool = false
        var provisionedSchedulerMCP: Bool = false
        /// Non-sensitive summary suitable for `openCodeMigrationLastError`.
        var lastError: String?

        var importedMCPServerNames: [String] { mcp.imported }
    }

    func needsMigration(project: RemoteProject) -> Bool {
        project.needsOpenCodeMigration
    }

    /// Idempotent migration entry point. Safe to call on chat open / send / runtime picker.
    @discardableResult
    func migrateIfNeeded(
        project: RemoteProject,
        modelContext: ModelContext?
    ) async -> MigrationReport {
        var report = MigrationReport()

        guard needsMigration(project: project) else {
            report.alreadyMigrated = project.openCodeMigrationVersion != nil
            return report
        }

        // 1) Promote runtime flag
        let previousRuntime = project.agentRuntimeRawValue
        project.selectedAgentRuntime = .openCode
        report.promotedRuntime = previousRuntime != CodingAgentRuntimeKind.openCode.rawValue

        // 2) Clear Claude proxy transport anchors (local chat messages stay)
        // Active Claude streams are not usable after promote — clear streaming id.
        project.clearClaudeProxyTransportState(clearActiveStreamingMessage: true)
        report.clearedProxyTransport = true

        // 3) Best-effort credential assist (copy-only, non-destructive)
        report.credentialProvidersCopied = copyCompatibleCredentialsIfNeeded()

        // 4) Soft rules auto-copy: legacy CLAUDE.md → AGENTS.md when missing
        do {
            report.rulesCopiedFrom = try await autoCopyLegacyRulesIfNeeded(for: project)
        } catch {
            let message = sanitizedError(error)
            report.lastError = report.lastError ?? message
            SSHLogger.log("Claude→OpenCode rules auto-copy failed: \(message)", level: .warning)
        }

        // 5) Path D MCP import (disk first; live API soft-fails)
        do {
            report.mcp = try await mcpService.migrateClaudeMCPToOpenCode(for: project)
        } catch {
            let message = sanitizedError(error)
            report.mcp.note = report.mcp.note ?? "mcp_import_failed"
            report.lastError = message
            SSHLogger.log("Claude→OpenCode MCP import failed: \(message)", level: .warning)
        }

        // 6) Ensure OpenCode session (best-effort; does not fail migration)
        do {
            _ = try await openCodeRuntime.ensureSession(for: project)
            report.ensuredSession = true
        } catch {
            let message = sanitizedError(error)
            report.lastError = report.lastError ?? message
            SSHLogger.log("Claude→OpenCode session ensure failed: \(message)", level: .warning)
        }

        // 7) Re-provision managed scheduler MCP on OpenCode only (best-effort)
        do {
            try await mcpService.ensureManagedSchedulerServerIfNeeded(for: project)
            report.provisionedSchedulerMCP = true
        } catch {
            let message = sanitizedError(error)
            report.lastError = report.lastError ?? message
            SSHLogger.log("Claude→OpenCode scheduler MCP provision failed: \(message)", level: .warning)
        }

        // 8) Stamp migration version so re-entry is a no-op
        project.openCodeMigrationVersion = ClaudeToOpenCodeMigration.currentVersion
        project.openCodeMigrationLastError = report.lastError
        project.updateLastModified()

        if let modelContext {
            try? modelContext.save()
        }

        report.didMigrate = true
        SSHLogger.log(
            "Claude→OpenCode migration complete for project \(project.id.uuidString.prefix(8))… importedMCP=\(report.mcp.imported.count) skippedExisting=\(report.mcp.skippedExisting.count) skippedManaged=\(report.mcp.skippedManaged.count) failed=\(report.mcp.failed.count) rules=\(report.rulesCopiedFrom ?? "none") session=\(report.ensuredSession)",
            level: .info
        )
        return report
    }

    /// Copy `.claude/CLAUDE.md` or root `CLAUDE.md` to `AGENTS.md` when the primary file is missing.
    /// Returns the relative source path when a copy happened.
    @discardableResult
    func autoCopyLegacyRulesIfNeeded(for project: RemoteProject) async throws -> String? {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        let agentsPath = AgentProjectFileLayout.remotePath(
            projectPath: project.path,
            relativePath: AgentProjectFileLayout.rulesPrimaryRelativePath
        )
        let legacyDirectoryPath = AgentProjectFileLayout.remotePath(
            projectPath: project.path,
            relativePath: AgentProjectFileLayout.legacyClaudeDirectoryRulesRelativePath
        )
        let legacyRootPath = AgentProjectFileLayout.remotePath(
            projectPath: project.path,
            relativePath: AgentProjectFileLayout.legacyClaudeRootRulesRelativePath
        )

        let marker = "__RULES_MIG_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        let command = [
            "AGENTS=\(shellEscape(agentsPath));",
            "LEGACY_DIR=\(shellEscape(legacyDirectoryPath));",
            "LEGACY_ROOT=\(shellEscape(legacyRootPath));",
            "if [ -f \"$AGENTS\" ]; then printf '%s' '\(marker)EXISTS';",
            "elif [ -f \"$LEGACY_DIR\" ]; then cp \"$LEGACY_DIR\" \"$AGENTS\" && printf '%s' '\(marker)COPIED:\(AgentProjectFileLayout.legacyClaudeDirectoryRulesRelativePath)';",
            "elif [ -f \"$LEGACY_ROOT\" ]; then cp \"$LEGACY_ROOT\" \"$AGENTS\" && printf '%s' '\(marker)COPIED:\(AgentProjectFileLayout.legacyClaudeRootRulesRelativePath)';",
            "else printf '%s' '\(marker)MISSING';",
            "fi"
        ].joined(separator: " ")

        let output = try await session.execute(command)
        guard let markerRange = output.range(of: marker) else {
            return nil
        }
        let payload = String(output[markerRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if payload.hasPrefix("COPIED:") {
            let source = String(payload.dropFirst("COPIED:".count))
            return source.isEmpty ? nil : source
        }
        return nil
    }

    private func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func copyCompatibleCredentialsIfNeeded() -> [String] {
        var copied: [String] = []
        for providerID in credentialProviderIDs {
            guard AIProviderCredentialMigration.canCopyLegacyAPIKeyForOpenCode(
                providerID: providerID,
                keychain: keychain
            ) else {
                continue
            }
            do {
                _ = try AIProviderCredentialMigration.copyLegacyAPIKeyForOpenCode(
                    providerID: providerID,
                    keychain: keychain
                )
                copied.append(providerID)
            } catch {
                SSHLogger.log(
                    "Credential assist skipped for \(providerID): \(sanitizedError(error))",
                    level: .debug
                )
            }
        }
        return copied
    }

    private func sanitizedError(_ error: Error) -> String {
        let text = error.localizedDescription
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count <= 180 {
            return text
        }
        return String(text.prefix(180))
    }
}
