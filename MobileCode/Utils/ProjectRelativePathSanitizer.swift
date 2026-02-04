//
//  ProjectRelativePathSanitizer.swift
//  CodeAgentsMobile
//
//  Purpose: Validate and normalize project-root-relative paths for codeagents_ui media.
//

import Foundation

enum ProjectRelativePathSanitizer {
    static func sanitize(_ raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return nil
        }

        trimmed = trimmed.replacingOccurrences(of: "\\", with: "/")

        while trimmed.hasPrefix("./") {
            trimmed = String(trimmed.dropFirst(2))
        }

        let components = trimmed
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)

        guard !components.isEmpty else { return nil }

        for component in components {
            if component == ".." {
                return nil
            }
            if component.isEmpty {
                return nil
            }
        }

        let normalized = components.joined(separator: "/")
        return normalized.isEmpty ? nil : normalized
    }
}
