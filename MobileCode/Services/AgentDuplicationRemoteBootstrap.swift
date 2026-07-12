//
//  AgentDuplicationRemoteBootstrap.swift
//  CodeAgentsMobile
//
//  Purpose: Build a single remote shell script for Duplicate Agent workspace setup.
//

import Foundation

/// Progress phases surfaced to Duplicate Agent UI.
enum DuplicateAgentProgress: String, Equatable, Sendable {
    case preparing
    case creatingFolder
    case copyingWorkspace
    case configuringTools
    case finishing

    var userLabel: String {
        switch self {
        case .preparing:
            return "Preparing…"
        case .creatingFolder:
            return "Creating folder…"
        case .copyingWorkspace:
            return "Copying workspace files…"
        case .configuringTools:
            return "Configuring tools…"
        case .finishing:
            return "Finishing…"
        }
    }
}

/// Pure helpers for one-shot remote bootstrap of a duplicated agent folder.
enum AgentDuplicationRemoteBootstrap {
    static let okMarker = "DUPLICATE_OK"
    static let existsMarker = "DUPLICATE_EXISTS"
    static let mkdirFailedMarker = "DUPLICATE_MKDIR_FAILED"

    /// Single remote script: exclusive mkdir + optional rules/skills/avatar file copies.
    /// Source and clone share a host — all copies are server-local (`cp`), never phone uploads.
    static func shellScript(
        sourcePath: String,
        clonePath: String,
        copyRules: Bool,
        copySkills: Bool,
        copyAvatarImage: Bool
    ) -> String {
        let qSource = SSHShellQuoting.quote(sourcePath)
        let qClone = SSHShellQuoting.quote(clonePath)
        let qParent = SSHShellQuoting.quote(
            AgentDuplicationPath.parentDirectory(of: clonePath) ?? (clonePath as NSString).deletingLastPathComponent
        )

        var lines: [String] = [
            "set +e",
            "SRC=\(qSource)",
            "DST=\(qClone)",
            "mkdir -p -- \(qParent)",
            "if mkdir -- \"$DST\" 2>/dev/null; then",
            "  :",
            "elif [ -d \"$DST\" ]; then",
            "  echo \(existsMarker)",
            "  exit 0",
            "else",
            "  echo \(mkdirFailedMarker)",
            "  exit 1",
            "fi",
        ]

        if copyRules {
            let agents = AgentProjectFileLayout.rulesPrimaryRelativePath
            let legacyDir = AgentProjectFileLayout.legacyClaudeDirectoryRulesRelativePath
            let legacyRoot = AgentProjectFileLayout.legacyClaudeRootRulesRelativePath
            lines += [
                "for f in \(shellSingleQuote(agents)) \(shellSingleQuote(legacyDir)) \(shellSingleQuote(legacyRoot)); do",
                "  if [ -f \"$SRC/$f\" ]; then",
                "    cp -- \"$SRC/$f\" \"$DST/\(agents)\"",
                "    break",
                "  fi",
                "done",
            ]
        }

        if copySkills {
            let skills = AgentProjectFileLayout.skillsInstallRelativePath
            let legacyClaude = AgentProjectFileLayout.legacyClaudeSkillsRelativePath
            let legacyAgents = AgentProjectFileLayout.legacyAgentsSkillsRelativePath
            lines += [
                "if [ -d \"$SRC/\(skills)\" ]; then",
                "  mkdir -p -- \"$DST/.opencode\"",
                "  rm -rf -- \"$DST/\(skills)\"",
                "  cp -a -- \"$SRC/\(skills)\" \"$DST/\(skills)\"",
                "elif [ -d \"$SRC/\(legacyClaude)\" ]; then",
                "  mkdir -p -- \"$DST/.opencode\"",
                "  rm -rf -- \"$DST/\(skills)\"",
                "  cp -a -- \"$SRC/\(legacyClaude)\" \"$DST/\(skills)\"",
                "elif [ -d \"$SRC/\(legacyAgents)\" ]; then",
                "  mkdir -p -- \"$DST/.opencode\"",
                "  rm -rf -- \"$DST/\(skills)\"",
                "  cp -a -- \"$SRC/\(legacyAgents)\" \"$DST/\(skills)\"",
                "fi",
            ]
        }

        if copyAvatarImage {
            let imageRel = AgentProjectFileLayout.avatarImageRelativePath
            lines += [
                "mkdir -p -- \"$DST/.codeagents\"",
                "if [ -f \"$SRC/\(imageRel)\" ]; then",
                "  cp -- \"$SRC/\(imageRel)\" \"$DST/\(imageRel)\"",
                "fi",
            ]
        }

        lines.append("echo \(okMarker)")
        return lines.joined(separator: "\n")
    }

    static func interpretOutput(_ raw: String) -> Result<Void, AgentDuplicationError> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains(existsMarker) {
            return .failure(.directoryAlreadyExists)
        }
        if text.contains(mkdirFailedMarker) {
            return .failure(.failedToCreateDirectory)
        }
        if text.contains(okMarker) {
            return .success(())
        }
        // Some shells echo only the last line; treat empty+success exit as ok only if marker present.
        return .failure(.failedToCreateDirectory)
    }

    private static func shellSingleQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}
