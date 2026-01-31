//
//  AgentRulesViewModel.swift
//  CodeAgentsMobile
//
//  Purpose: Load and save agent rules stored in .claude/CLAUDE.md
//

import Foundation
import SwiftUI

@MainActor
final class AgentRulesViewModel: ObservableObject {
    @Published var content = ""
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var isMissingFile = false
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
            let rulesPath = rulesFilePath(for: project)
            let markerToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let markerStart = "__RULES_START_\(markerToken)__"
            let markerEnd = "__RULES_END_\(markerToken)__"
            let payloadPrefix = "EXISTS:"
            let command = [
                "printf '\(markerStart)';",
                "if [ -f '\(rulesPath)' ]; then",
                "printf '\(payloadPrefix)';",
                "(base64 -w 0 '\(rulesPath)' 2>/dev/null || base64 '\(rulesPath)');",
                "else",
                "printf 'MISSING';",
                "fi;",
                "printf '\(markerEnd)'",
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
                return
            }

            guard payload.hasPrefix(payloadPrefix) else {
                loadErrorMessage = "Unexpected rules output format."
                return
            }

            let base64Payload = String(payload.dropFirst(payloadPrefix.count))
            let cleanedBase64 = base64Payload
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()

            if cleanedBase64.isEmpty {
                content = ""
                originalContent = ""
                isMissingFile = false
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
            let rulesPath = rulesFilePath(for: project)
            let rulesDirectory = (rulesPath as NSString).deletingLastPathComponent
            _ = try await session.execute("mkdir -p '\(rulesDirectory)'")

            guard let data = content.data(using: .utf8) else {
                throw SSHError.fileTransferFailed("Invalid rules content")
            }

            let base64Content = data.base64EncodedString()
            let writeCommand = "printf '%s' '\(base64Content)' | base64 -d > '\(rulesPath)'"
            _ = try await session.execute(writeCommand)

            originalContent = content
            isMissingFile = false
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }

    private func rulesFilePath(for project: RemoteProject) -> String {
        (project.path as NSString).appendingPathComponent(".claude/CLAUDE.md")
    }
}
