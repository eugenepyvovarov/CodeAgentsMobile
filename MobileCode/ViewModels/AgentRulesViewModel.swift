//
//  AgentRulesViewModel.swift
//  CodeAgentsMobile
//
//  Purpose: Load and save agent rules stored in AGENTS.md with legacy fallbacks.
//

import Foundation
import SwiftUI

@MainActor
final class AgentRulesViewModel: ObservableObject {
    @Published var content = ""
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var isMissingFile = false
    @Published var loadedRulesRelativePath = AgentProjectFileLayout.rulesPrimaryRelativePath
    @Published var targetRulesRelativePath = AgentProjectFileLayout.rulesPrimaryRelativePath
    @Published var shouldOfferMigration = false
    @Published var loadErrorMessage: String?
    @Published var saveErrorMessage: String?

    private let sshService = ServiceManager.shared.sshService
    private var originalContent = ""
    private var loadToken = UUID()

    var hasUnsavedChanges: Bool {
        content != originalContent
    }

    func reset() {
        content = ""
        originalContent = ""
        isLoading = false
        isSaving = false
        isMissingFile = false
        loadedRulesRelativePath = AgentProjectFileLayout.rulesPrimaryRelativePath
        targetRulesRelativePath = AgentProjectFileLayout.rulesPrimaryRelativePath
        shouldOfferMigration = false
        loadErrorMessage = nil
        saveErrorMessage = nil
    }

    func load(for project: RemoteProject) async {
        let token = UUID()
        loadToken = token
        isLoading = true
        loadErrorMessage = nil
        saveErrorMessage = nil
        isMissingFile = false

        defer {
            if loadToken == token {
                isLoading = false
            }
        }

        do {
            let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
            let markerToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let markerStart = "__RULES_START_\(markerToken)__"
            let markerEnd = "__RULES_END_\(markerToken)__"
            let payloadPrefix = "EXISTS"
            let agentsPath = shellEscaped(rulesFilePath(for: project, relativePath: AgentProjectFileLayout.rulesPrimaryRelativePath))
            let legacyClaudeDirectoryPath = shellEscaped(
                rulesFilePath(for: project, relativePath: AgentProjectFileLayout.legacyClaudeDirectoryRulesRelativePath)
            )
            let legacyClaudeRootPath = shellEscaped(
                rulesFilePath(for: project, relativePath: AgentProjectFileLayout.legacyClaudeRootRulesRelativePath)
            )
            let command = [
                "printf \(shellEscaped(markerStart));",
                "if [ -f \(agentsPath) ]; then",
                "printf \(shellEscaped("\(payloadPrefix):\(AgentRulesFileKind.agents.rawValue):"));",
                "(base64 -w 0 \(agentsPath) 2>/dev/null || base64 \(agentsPath));",
                "elif [ -f \(legacyClaudeDirectoryPath) ]; then",
                "printf \(shellEscaped("\(payloadPrefix):\(AgentRulesFileKind.legacyClaudeDirectory.rawValue):"));",
                "(base64 -w 0 \(legacyClaudeDirectoryPath) 2>/dev/null || base64 \(legacyClaudeDirectoryPath));",
                "elif [ -f \(legacyClaudeRootPath) ]; then",
                "printf \(shellEscaped("\(payloadPrefix):\(AgentRulesFileKind.legacyClaudeRoot.rawValue):"));",
                "(base64 -w 0 \(legacyClaudeRootPath) 2>/dev/null || base64 \(legacyClaudeRootPath));",
                "else",
                "printf \(shellEscaped("MISSING"));",
                "fi;",
                "printf \(shellEscaped(markerEnd))",
            ].joined(separator: " ")
            let output = try await session.execute(command)

            guard loadToken == token else { return }

            guard let startRange = output.range(of: markerStart),
                  let endRange = output.range(of: markerEnd),
                  startRange.upperBound <= endRange.lowerBound else {
                loadErrorMessage = "Unable to read rules file output."
                return
            }

            let payload = String(output[startRange.upperBound..<endRange.lowerBound])
            if payload == "MISSING" {
                content = ""
                originalContent = ""
                isMissingFile = true
                applyRulesSelection(.missing)
                return
            }

            guard let parsed = parseFoundRulesPayload(payload, payloadPrefix: payloadPrefix) else {
                loadErrorMessage = "Unexpected rules output format."
                return
            }

            let (kind, base64Payload) = parsed
            let cleanedBase64 = base64Payload
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()

            if cleanedBase64.isEmpty {
                content = ""
                originalContent = ""
                isMissingFile = false
                applyRulesSelection(kind)
                return
            }

            guard let data = Data(base64Encoded: cleanedBase64),
                  let decoded = String(data: data, encoding: .utf8) else {
                loadErrorMessage = "Failed to decode rules content."
                return
            }

            content = decoded
            originalContent = decoded
            isMissingFile = false
            applyRulesSelection(kind)
        } catch {
            guard loadToken == token else { return }
            loadErrorMessage = error.localizedDescription
        }
    }

    func save(for project: RemoteProject) async {
        loadToken = UUID()
        isSaving = true
        saveErrorMessage = nil
        loadErrorMessage = nil

        defer {
            isSaving = false
        }

        do {
            let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
            let rulesPath = rulesFilePath(for: project, relativePath: targetRulesRelativePath)
            let rulesDirectory = (rulesPath as NSString).deletingLastPathComponent
            _ = try await session.execute("mkdir -p \(shellEscaped(rulesDirectory))")

            let updatedContent = CodeAgentsUIRules.ensuringToolCallGuard(in: content)
            if updatedContent != content {
                content = updatedContent
            }

            guard let data = content.data(using: .utf8) else {
                throw SSHError.fileTransferFailed("Invalid rules content")
            }

            let base64Content = data.base64EncodedString()
            let writeCommand = "printf '%s' \(shellEscaped(base64Content)) | base64 -d > \(shellEscaped(rulesPath))"
            _ = try await session.execute(writeCommand)

            do {
                try await CodeAgentsUIRules.ensureRulesFile(
                    session: session,
                    project: project,
                    onlyIfMissing: false
                )
            } catch {
                saveErrorMessage = "Saved rules, but failed to update codeagents-ui rules: \(error.localizedDescription)"
                return
            }

            originalContent = content
            isMissingFile = false
            applyRulesSelection(.agents)
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }

    private func parseFoundRulesPayload(
        _ payload: String,
        payloadPrefix: String
    ) -> (AgentRulesFileKind, String)? {
        let prefix = "\(payloadPrefix):"
        guard payload.hasPrefix(prefix) else { return nil }

        let remainder = String(payload.dropFirst(prefix.count))
        guard let separator = remainder.firstIndex(of: ":") else { return nil }

        let kindRaw = String(remainder[..<separator])
        guard let kind = AgentRulesFileKind(rawValue: kindRaw) else { return nil }

        let base64Start = remainder.index(after: separator)
        return (kind, String(remainder[base64Start...]))
    }

    private func applyRulesSelection(_ kind: AgentRulesFileKind) {
        let selection = AgentProjectFileLayout.selectRulesFile(
            hasAgents: kind == .agents,
            hasLegacyClaudeDirectory: kind == .legacyClaudeDirectory,
            hasLegacyClaudeRoot: kind == .legacyClaudeRoot
        )
        loadedRulesRelativePath = selection.readRelativePath
        targetRulesRelativePath = selection.writeRelativePath
        shouldOfferMigration = selection.shouldOfferMigration
    }

    private func rulesFilePath(for project: RemoteProject, relativePath: String) -> String {
        AgentProjectFileLayout.remotePath(projectPath: project.path, relativePath: relativePath)
    }

    private func shellEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}
