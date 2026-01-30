//
//  ProjectPathResolver.swift
//  CodeAgentsMobile
//
//  Purpose: Helper utilities for converting absolute project paths to relative ones.
//

import Foundation

struct ProjectPathResolver {
    static func relativePath(absolutePath: String, projectRoot: String) -> String? {
        let trimmedRoot = projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = absolutePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRoot.isEmpty, !trimmedPath.isEmpty else { return nil }

        let normalizedRoot = trimmedRoot.hasSuffix("/") ? String(trimmedRoot.dropLast()) : trimmedRoot
        guard trimmedPath.hasPrefix(normalizedRoot) else { return nil }

        let startIndex = trimmedPath.index(trimmedPath.startIndex, offsetBy: normalizedRoot.count)
        var remainder = String(trimmedPath[startIndex...])
        if remainder.hasPrefix("/") {
            remainder.removeFirst()
        }
        return remainder.isEmpty ? nil : remainder
    }
}

