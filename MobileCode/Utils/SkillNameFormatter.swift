//
//  SkillNameFormatter.swift
//  CodeAgentsMobile
//
//  Purpose: Consistent display formatting for skill names
//

import Foundation

enum SkillNameFormatter {
    static func displayName(from raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "-", with: " ")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return raw
        }
        return trimmed.capitalized
    }
}
