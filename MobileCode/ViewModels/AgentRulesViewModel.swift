//
//  AgentRulesViewModel.swift
//  CodeAgentsMobile
//
//  Purpose: Load and save multi-aspect agent rules linked into AGENTS.md.
//

import Foundation
import SwiftUI

struct AgentRulesAspectDraft: Equatable {
    var content: String
    var originalContent: String
    var relativePath: String
    var isMissingFile: Bool

    var hasUnsavedChanges: Bool {
        content != originalContent
    }

    var isEmpty: Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func empty(for aspect: AgentRulesAspect) -> AgentRulesAspectDraft {
        AgentRulesAspectDraft(
            content: "",
            originalContent: "",
            relativePath: aspect.relativePath,
            isMissingFile: true
        )
    }
}

@MainActor
final class AgentRulesViewModel: ObservableObject {
    @Published private(set) var drafts: [AgentRulesAspect: AgentRulesAspectDraft] = [
        .personality: .empty(for: .personality),
        .codeAgentsUI: .empty(for: .codeAgentsUI),
    ]
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var didMigrateFromLegacy = false
    @Published var migrationSourceRelativePath: String?
    @Published var assembledRulesRelativePath = AgentProjectFileLayout.rulesPrimaryRelativePath
    @Published var loadErrorMessage: String?
    @Published var saveErrorMessage: String?

    /// Compatibility: monolithic content (personality only for overview/status).
    var content: String {
        get { drafts[.personality]?.content ?? "" }
        set {
            var draft = drafts[.personality] ?? .empty(for: .personality)
            draft.content = newValue
            drafts[.personality] = draft
        }
    }

    var isMissingFile: Bool {
        drafts[.personality]?.isMissingFile == true
            && drafts[.codeAgentsUI]?.isMissingFile == true
            && (drafts[.personality]?.isEmpty ?? true)
    }

    var hasUnsavedChanges: Bool {
        drafts.values.contains(where: \.hasUnsavedChanges)
    }

    var hasPersonalityContent: Bool {
        !(drafts[.personality]?.isEmpty ?? true)
    }

    private let sshService = ServiceManager.shared.sshService
    private var loadToken = UUID()

    func reset() {
        drafts = [
            .personality: .empty(for: .personality),
            .codeAgentsUI: .empty(for: .codeAgentsUI),
        ]
        isLoading = false
        isSaving = false
        didMigrateFromLegacy = false
        migrationSourceRelativePath = nil
        assembledRulesRelativePath = AgentProjectFileLayout.rulesPrimaryRelativePath
        loadErrorMessage = nil
        saveErrorMessage = nil
    }

    func draft(for aspect: AgentRulesAspect) -> AgentRulesAspectDraft {
        drafts[aspect] ?? .empty(for: aspect)
    }

    func updateContent(_ text: String, for aspect: AgentRulesAspect) {
        var draft = drafts[aspect] ?? .empty(for: aspect)
        draft.content = text
        drafts[aspect] = draft
    }

    func load(for project: RemoteProject) async {
        let token = UUID()
        loadToken = token
        isLoading = true
        loadErrorMessage = nil
        saveErrorMessage = nil
        didMigrateFromLegacy = false
        migrationSourceRelativePath = nil

        defer {
            if loadToken == token {
                isLoading = false
            }
        }

        do {
            let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
            let snapshot = try await readSnapshot(session: session, project: project)
            guard loadToken == token else { return }

            let resolved = resolveDrafts(from: snapshot)
            drafts = resolved.drafts
            didMigrateFromLegacy = resolved.didMigrate
            migrationSourceRelativePath = resolved.migrationSource

            // Persist migrated aspect split so disk matches what the editor shows.
            if resolved.shouldWriteMigration {
                try await persistAll(
                    session: session,
                    project: project,
                    personality: resolved.drafts[.personality]?.content ?? "",
                    ui: resolved.drafts[.codeAgentsUI]?.content ?? CodeAgentsUIRules.rulesMarkdown
                )
                guard loadToken == token else { return }
                // Mark as saved (disk matches drafts).
                for aspect in AgentRulesAspect.allCases {
                    var draft = drafts[aspect] ?? .empty(for: aspect)
                    draft.originalContent = draft.content
                    draft.isMissingFile = false
                    drafts[aspect] = draft
                }
            }
        } catch {
            guard loadToken == token else { return }
            loadErrorMessage = error.localizedDescription
        }
    }

    func save(for project: RemoteProject) async {
        await saveAspect(.personality, for: project)
    }

    func saveAspect(_ aspect: AgentRulesAspect, for project: RemoteProject) async {
        loadToken = UUID()
        isSaving = true
        saveErrorMessage = nil
        loadErrorMessage = nil

        defer {
            isSaving = false
        }

        do {
            let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
            let draft = drafts[aspect] ?? .empty(for: aspect)
            try await CodeAgentsUIRules.saveAspect(
                aspect,
                content: draft.content,
                session: session,
                project: project
            )

            // Reload sibling + normalize local state from what we wrote.
            var updated = draft
            if aspect == .codeAgentsUI {
                updated.content = CodeAgentsUIRules.ensuringToolCallGuard(in: draft.content)
            }
            updated.originalContent = updated.content
            updated.isMissingFile = false
            drafts[aspect] = updated

            // If sibling was missing, ensureRules-style defaults may have created it — refresh lightly.
            if let other = AgentRulesAspect.allCases.first(where: { $0 != aspect }),
               drafts[other]?.isMissingFile == true {
                let otherPath = AgentProjectFileLayout.remotePath(
                    projectPath: project.path,
                    relativePath: other.relativePath
                )
                if let text = try await readFile(session: session, path: otherPath) {
                    drafts[other] = AgentRulesAspectDraft(
                        content: text,
                        originalContent: text,
                        relativePath: other.relativePath,
                        isMissingFile: false
                    )
                }
            }

            didMigrateFromLegacy = false
            migrationSourceRelativePath = nil
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }

    func reloadAspect(_ aspect: AgentRulesAspect, for project: RemoteProject) async {
        // Full load keeps aspects consistent with AGENTS.md assembly.
        await load(for: project)
        _ = aspect
    }

    // MARK: - Snapshot / migration

    private struct RemoteSnapshot {
        var personality: String?
        var ui: String?
        var agents: String?
        var legacyClaudeDirectory: String?
        var legacyClaudeRoot: String?
    }

    private struct ResolvedDrafts {
        var drafts: [AgentRulesAspect: AgentRulesAspectDraft]
        var didMigrate: Bool
        var migrationSource: String?
        var shouldWriteMigration: Bool
    }

    private func resolveDrafts(from snapshot: RemoteSnapshot) -> ResolvedDrafts {
        let hasPersonalityFile = snapshot.personality != nil
        let hasUIFile = snapshot.ui != nil

        if hasPersonalityFile || hasUIFile {
            let personalityText = snapshot.personality ?? ""
            let uiText: String
            if let ui = snapshot.ui, !ui.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                uiText = ui
            } else {
                uiText = CodeAgentsUIRules.rulesMarkdown
            }

            var map: [AgentRulesAspect: AgentRulesAspectDraft] = [:]
            map[.personality] = AgentRulesAspectDraft(
                content: personalityText,
                originalContent: personalityText,
                relativePath: AgentRulesAspect.personality.relativePath,
                isMissingFile: !hasPersonalityFile
            )
            map[.codeAgentsUI] = AgentRulesAspectDraft(
                content: uiText,
                originalContent: uiText,
                relativePath: AgentRulesAspect.codeAgentsUI.relativePath,
                isMissingFile: !hasUIFile
            )

            // Aspect files present but UI missing → write default UI + reassemble.
            let needsWrite = !hasUIFile || !hasPersonalityFile
            return ResolvedDrafts(
                drafts: map,
                didMigrate: false,
                migrationSource: nil,
                shouldWriteMigration: needsWrite
            )
        }

        // No aspect files — migrate from AGENTS.md or legacy CLAUDE.md.
        if let agents = snapshot.agents {
            let extracted = AgentRulesAssembly.extractAspects(from: agents)
            let personality = extracted.personality
            let ui = (extracted.uiRules?.isEmpty == false)
                ? (extracted.uiRules ?? CodeAgentsUIRules.rulesMarkdown)
                : CodeAgentsUIRules.rulesMarkdown

            // If the monolith was only UI rules, personality ends up empty — correct.
            return makeMigrationResult(
                personality: personality,
                ui: ui,
                source: AgentProjectFileLayout.rulesPrimaryRelativePath,
                shouldWrite: true
            )
        }

        if let legacy = snapshot.legacyClaudeDirectory {
            let extracted = AgentRulesAssembly.extractAspects(from: legacy)
            return makeMigrationResult(
                personality: extracted.personality,
                ui: extracted.uiRules ?? CodeAgentsUIRules.rulesMarkdown,
                source: AgentProjectFileLayout.legacyClaudeDirectoryRulesRelativePath,
                shouldWrite: true
            )
        }

        if let legacy = snapshot.legacyClaudeRoot {
            let extracted = AgentRulesAssembly.extractAspects(from: legacy)
            return makeMigrationResult(
                personality: extracted.personality,
                ui: extracted.uiRules ?? CodeAgentsUIRules.rulesMarkdown,
                source: AgentProjectFileLayout.legacyClaudeRootRulesRelativePath,
                shouldWrite: true
            )
        }

        // Nothing on disk.
        return ResolvedDrafts(
            drafts: [
                .personality: .empty(for: .personality),
                .codeAgentsUI: AgentRulesAspectDraft(
                    content: CodeAgentsUIRules.rulesMarkdown,
                    originalContent: CodeAgentsUIRules.rulesMarkdown,
                    relativePath: AgentRulesAspect.codeAgentsUI.relativePath,
                    isMissingFile: true
                ),
            ],
            didMigrate: false,
            migrationSource: nil,
            shouldWriteMigration: false
        )
    }

    private func makeMigrationResult(
        personality: String,
        ui: String,
        source: String,
        shouldWrite: Bool
    ) -> ResolvedDrafts {
        ResolvedDrafts(
            drafts: [
                .personality: AgentRulesAspectDraft(
                    content: personality,
                    originalContent: personality,
                    relativePath: AgentRulesAspect.personality.relativePath,
                    isMissingFile: false
                ),
                .codeAgentsUI: AgentRulesAspectDraft(
                    content: ui,
                    originalContent: ui,
                    relativePath: AgentRulesAspect.codeAgentsUI.relativePath,
                    isMissingFile: false
                ),
            ],
            didMigrate: true,
            migrationSource: source,
            shouldWriteMigration: shouldWrite
        )
    }

    private func persistAll(
        session: SSHSession,
        project: RemoteProject,
        personality: String,
        ui: String
    ) async throws {
        try await writeFile(
            session: session,
            project: project,
            relativePath: AgentRulesAspect.personality.relativePath,
            content: personality
        )
        try await writeFile(
            session: session,
            project: project,
            relativePath: AgentRulesAspect.codeAgentsUI.relativePath,
            content: ui
        )
        let assembled = AgentRulesAssembly.assemble(personality: personality, uiRules: ui)
        try await writeFile(
            session: session,
            project: project,
            relativePath: AgentProjectFileLayout.rulesPrimaryRelativePath,
            content: assembled
        )
    }

    private func readSnapshot(session: SSHSession, project: RemoteProject) async throws -> RemoteSnapshot {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let markerStart = "__RULES_START_\(token)__"
        let markerEnd = "__RULES_END_\(token)__"

        func path(_ relative: String) -> String {
            shellEscaped(
                AgentProjectFileLayout.remotePath(projectPath: project.path, relativePath: relative)
            )
        }

        func segment(_ key: String, _ relative: String) -> String {
            let p = path(relative)
            return [
                "printf \(shellEscaped("\(key):"));",
                "if [ -f \(p) ]; then (base64 -w 0 \(p) 2>/dev/null || base64 \(p)); else printf MISSING; fi;",
                "printf '\\n';",
            ].joined(separator: " ")
        }

        let command = [
            "printf \(shellEscaped(markerStart));",
            segment("P", AgentProjectFileLayout.rulesPersonalityRelativePath),
            segment("U", AgentProjectFileLayout.rulesUIRelativePath),
            segment("A", AgentProjectFileLayout.rulesPrimaryRelativePath),
            segment("L1", AgentProjectFileLayout.legacyClaudeDirectoryRulesRelativePath),
            segment("L2", AgentProjectFileLayout.legacyClaudeRootRulesRelativePath),
            "printf \(shellEscaped(markerEnd))",
        ].joined(separator: " ")

        let output = try await session.execute(command)
        guard let startRange = output.range(of: markerStart),
              let endRange = output.range(of: markerEnd),
              startRange.upperBound <= endRange.lowerBound else {
            throw SSHError.commandFailed("Unable to read rules file output.")
        }

        let body = String(output[startRange.upperBound..<endRange.lowerBound])
        var snapshot = RemoteSnapshot()
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineString = String(line)
            guard let colon = lineString.firstIndex(of: ":") else { continue }
            let key = String(lineString[..<colon])
            let value = String(lineString[lineString.index(after: colon)...])
            let decoded = decodeBase64OrMissing(value)
            switch key {
            case "P": snapshot.personality = decoded
            case "U": snapshot.ui = decoded
            case "A": snapshot.agents = decoded
            case "L1": snapshot.legacyClaudeDirectory = decoded
            case "L2": snapshot.legacyClaudeRoot = decoded
            default: break
            }
        }
        return snapshot
    }

    private func readFile(session: SSHSession, path: String) async throws -> String? {
        let escaped = shellEscaped(path)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let start = "__R_\(token)__"
        let end = "__E_\(token)__"
        let command = [
            "printf \(shellEscaped(start));",
            "if [ -f \(escaped) ]; then (base64 -w 0 \(escaped) 2>/dev/null || base64 \(escaped)); else printf MISSING; fi;",
            "printf \(shellEscaped(end))",
        ].joined(separator: " ")
        let output = try await session.execute(command)
        guard let startRange = output.range(of: start),
              let endRange = output.range(of: end),
              startRange.upperBound <= endRange.lowerBound else {
            return nil
        }
        return decodeBase64OrMissing(String(output[startRange.upperBound..<endRange.lowerBound]))
    }

    private func writeFile(
        session: SSHSession,
        project: RemoteProject,
        relativePath: String,
        content: String
    ) async throws {
        let fullPath = AgentProjectFileLayout.remotePath(
            projectPath: project.path,
            relativePath: relativePath
        )
        let directory = (fullPath as NSString).deletingLastPathComponent
        let base64 = Data(content.utf8).base64EncodedString()
        let command = [
            "mkdir -p \(shellEscaped(directory))",
            "printf '%s' \(shellEscaped(base64)) | base64 -d > \(shellEscaped(fullPath))",
        ].joined(separator: " && ")
        _ = try await session.execute(command)
    }

    private func decodeBase64OrMissing(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "MISSING" {
            return nil
        }
        let cleaned = trimmed.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let data = Data(base64Encoded: cleaned),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private func shellEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}
