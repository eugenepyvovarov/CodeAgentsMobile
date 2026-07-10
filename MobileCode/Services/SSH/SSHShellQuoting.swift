//
//  SSHShellQuoting.swift
//  CodeAgentsMobile
//
//  Purpose: Safe POSIX shell argument quoting and path-component validation.
//

import Foundation

enum SSHShellQuoting {
    /// Quote a string for safe inclusion as a single POSIX shell argument (single-quoted form).
    static func quote(_ value: String) -> String {
        // Close quote, insert escaped apostrophe, reopen quote.
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// True when `name` is a single safe path component (no slash, no traversal, no controls).
    static func isSafePathComponent(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed != "." && trimmed != ".." else { return false }
        if trimmed.contains("/") || trimmed.contains("\\") { return false }
        if trimmed.contains("\0") { return false }
        // Reject ASCII control characters.
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return false
        }
        return true
    }

    /// Validate and return a trimmed path component, or nil if unsafe.
    static func sanitizedPathComponent(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafePathComponent(trimmed) else { return nil }
        return trimmed
    }
}
