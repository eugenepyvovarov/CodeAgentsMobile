//
//  AgentDuplicationPath.swift
//  CodeAgentsMobile
//
//  Purpose: Pure helpers for Duplicate Agent path/name resolution (unit-testable).
//

import Foundation

enum AgentDuplicationPath {
    /// Parent directory of a remote agent path (`/a/b/c` → `/a/b`).
    static func parentDirectory(of path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = PathUtils.normalize(trimmed)
        if normalized == "/" { return nil }
        let parent = (normalized as NSString).deletingLastPathComponent
        if parent.isEmpty { return "/" }
        return parent
    }

    /// Join parent + folder name with a single slash (no `..` resolution beyond PathUtils.normalize on parent).
    static func join(parent: String, folderName: String) -> String {
        let base = parent.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") {
            return base + name
        }
        if base.isEmpty {
            return name
        }
        return base + "/" + name
    }

    /// Default display title for a clone: `"{source} Copy"`.
    static func defaultDisplayName(from sourceTitle: String) -> String {
        let trimmed = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Agent Copy"
        }
        return "\(trimmed) Copy"
    }

    /// Suggest a folder component from a display name (spaces → hyphens, sanitized).
    static func suggestedFolderName(from displayName: String) -> String? {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let collapsed = trimmed
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        return SSHShellQuoting.sanitizedPathComponent(collapsed)
    }

    /// Resolve display name for SwiftData: nil when equal to folder name (matches create-agent).
    static func resolvedDisplayName(displayName: String, folderName: String) -> String? {
        let display = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if display.isEmpty || display == folder {
            return nil
        }
        return display
    }

    /// Field validation without SSH (empty display / unsafe folder).
    static func validateRequestFields(displayName: String, folderName: String) -> AgentDuplicationError? {
        let display = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if display.isEmpty {
            return .emptyDisplayName
        }
        guard SSHShellQuoting.sanitizedPathComponent(folderName) != nil else {
            return .invalidFolderName
        }
        return nil
    }

    /// Suggest an alternate folder name when the preferred one collides (`blog-copy` → `blog-copy-2`).
    static func nextFolderNameCandidate(base: String, attempt: Int) -> String? {
        guard attempt >= 2 else {
            return SSHShellQuoting.sanitizedPathComponent(base)
        }
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return SSHShellQuoting.sanitizedPathComponent("\(trimmed)-\(attempt)")
    }
}
