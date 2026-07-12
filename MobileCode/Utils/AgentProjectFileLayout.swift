//
//  AgentProjectFileLayout.swift
//  CodeAgentsMobile
//
//  Purpose: Central project file locations for agent runtime metadata.
//

import Foundation

enum AgentRulesFileKind: String {
    case agents
    case legacyClaudeDirectory
    case legacyClaudeRoot
    case missing

    var relativePath: String {
        switch self {
        case .agents:
            return AgentProjectFileLayout.rulesPrimaryRelativePath
        case .legacyClaudeDirectory:
            return AgentProjectFileLayout.legacyClaudeDirectoryRulesRelativePath
        case .legacyClaudeRoot:
            return AgentProjectFileLayout.legacyClaudeRootRulesRelativePath
        case .missing:
            return AgentProjectFileLayout.rulesPrimaryRelativePath
        }
    }

    var displayName: String {
        switch self {
        case .agents:
            return AgentProjectFileLayout.rulesPrimaryRelativePath
        case .legacyClaudeDirectory:
            return AgentProjectFileLayout.legacyClaudeDirectoryRulesRelativePath
        case .legacyClaudeRoot:
            return AgentProjectFileLayout.legacyClaudeRootRulesRelativePath
        case .missing:
            return AgentProjectFileLayout.rulesPrimaryRelativePath
        }
    }

    var isLegacy: Bool {
        switch self {
        case .legacyClaudeDirectory, .legacyClaudeRoot:
            return true
        case .agents, .missing:
            return false
        }
    }
}

struct AgentRulesFileCandidate: Equatable {
    let kind: AgentRulesFileKind
    let relativePath: String
}

struct AgentRulesFileSelection: Equatable {
    let kind: AgentRulesFileKind
    let readRelativePath: String
    let writeRelativePath: String

    var shouldOfferMigration: Bool {
        kind.isLegacy
    }
}

enum AgentProjectFileLayout {
    /// OpenCode entrypoint — assembled from aspect files under `rulesDirectoryRelativePath`.
    static let rulesPrimaryRelativePath = "AGENTS.md"
    /// Source-of-truth aspect files (`personality.md`, `codeagents-ui.md`).
    static let rulesDirectoryRelativePath = ".codeagents/rules"
    static let rulesPersonalityRelativePath = AgentRulesAspect.personality.relativePath
    static let rulesUIRelativePath = AgentRulesAspect.codeAgentsUI.relativePath

    static let legacyClaudeDirectoryRulesRelativePath = ".claude/CLAUDE.md"
    static let legacyClaudeRootRulesRelativePath = "CLAUDE.md"

    static let skillsInstallRelativePath = ".opencode/skills"
    static let legacyClaudeSkillsRelativePath = ".claude/skills"
    static let legacyAgentsSkillsRelativePath = ".agents/skills"

    static let attachmentsRelativePath = ".codeagents/attachments"
    static let legacyAttachmentsRelativePath = ".claude/attachments"

    static let identityRelativePath = ".codeagents/codeagents.json"
    static let legacyIdentityRelativePath = ".claude/codeagents.json"

    /// Default image blob for agent avatars (metadata lives in `codeagents.json`).
    static let avatarImageRelativePath = ".codeagents/avatar.png"
    /// Managed local MCP server script for avatar tools.
    static let avatarMCPScriptRelativePath = ".codeagents/mcp/codeagents_avatar_mcp.py"

    static let rulesReadCandidates: [AgentRulesFileCandidate] = [
        AgentRulesFileCandidate(kind: .agents, relativePath: rulesPrimaryRelativePath),
        AgentRulesFileCandidate(kind: .legacyClaudeDirectory, relativePath: legacyClaudeDirectoryRulesRelativePath),
        AgentRulesFileCandidate(kind: .legacyClaudeRoot, relativePath: legacyClaudeRootRulesRelativePath)
    ]

    static let skillLookupRelativePaths: [String] = [
        skillsInstallRelativePath,
        legacyClaudeSkillsRelativePath,
        legacyAgentsSkillsRelativePath
    ]

    static func selectRulesFile(
        hasAgents: Bool,
        hasLegacyClaudeDirectory: Bool,
        hasLegacyClaudeRoot: Bool
    ) -> AgentRulesFileSelection {
        if hasAgents {
            return AgentRulesFileSelection(
                kind: .agents,
                readRelativePath: rulesPrimaryRelativePath,
                writeRelativePath: rulesPrimaryRelativePath
            )
        }
        if hasLegacyClaudeDirectory {
            return AgentRulesFileSelection(
                kind: .legacyClaudeDirectory,
                readRelativePath: legacyClaudeDirectoryRulesRelativePath,
                writeRelativePath: rulesPrimaryRelativePath
            )
        }
        if hasLegacyClaudeRoot {
            return AgentRulesFileSelection(
                kind: .legacyClaudeRoot,
                readRelativePath: legacyClaudeRootRulesRelativePath,
                writeRelativePath: rulesPrimaryRelativePath
            )
        }
        return AgentRulesFileSelection(
            kind: .missing,
            readRelativePath: rulesPrimaryRelativePath,
            writeRelativePath: rulesPrimaryRelativePath
        )
    }

    /// Whether migration should auto-copy a legacy Claude rules file into `AGENTS.md`.
    /// Never overwrites an existing `AGENTS.md`.
    static func shouldAutoCopyLegacyRulesToAgents(
        hasAgents: Bool,
        hasLegacyClaudeDirectory: Bool,
        hasLegacyClaudeRoot: Bool
    ) -> Bool {
        !hasAgents && (hasLegacyClaudeDirectory || hasLegacyClaudeRoot)
    }

    /// Preferred legacy source path (relative) when auto-copying rules.
    static func preferredLegacyRulesRelativePath(
        hasLegacyClaudeDirectory: Bool,
        hasLegacyClaudeRoot: Bool
    ) -> String? {
        if hasLegacyClaudeDirectory {
            return legacyClaudeDirectoryRulesRelativePath
        }
        if hasLegacyClaudeRoot {
            return legacyClaudeRootRulesRelativePath
        }
        return nil
    }

    static func remotePath(projectPath: String, relativePath: String) -> String {
        PathUtils.join(projectPath, relativePath)
    }

    static func attachmentReference(fileName: String) -> String {
        PathUtils.join(attachmentsRelativePath, fileName)
    }

    static func attachmentDisplayName(for reference: String) -> String {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "File" }

        let lastComponent = (trimmed as NSString).lastPathComponent
        if isManagedAttachmentReference(trimmed), let displayName = stripUploadPrefix(from: lastComponent) {
            return displayName
        }

        return lastComponent.isEmpty ? trimmed : lastComponent
    }

    private static func isManagedAttachmentReference(_ reference: String) -> Bool {
        reference.hasPrefix("\(attachmentsRelativePath)/")
            || reference.hasPrefix("\(legacyAttachmentsRelativePath)/")
    }

    private static func stripUploadPrefix(from fileName: String) -> String? {
        guard let dashIndex = fileName.firstIndex(of: "-") else { return nil }
        let prefixLength = fileName.distance(from: fileName.startIndex, to: dashIndex)
        guard prefixLength == 8 else { return nil }

        let nameStart = fileName.index(after: dashIndex)
        let withoutPrefix = String(fileName[nameStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return withoutPrefix.isEmpty ? nil : withoutPrefix
    }
}
