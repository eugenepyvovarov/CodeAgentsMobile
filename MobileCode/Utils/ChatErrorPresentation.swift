//
//  ChatErrorPresentation.swift
//  CodeAgentsMobile
//
//  Purpose: Split + humanize app error messages for the chat error banner.
//

import Foundation

enum ChatErrorPresentation {
    struct Parts: Equatable {
        let title: String
        let detail: String?
    }

    /// Prefer "Title: detail" when present; otherwise treat the whole string as the title.
    static func parts(from raw: String) -> Parts {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Parts(title: "Something went wrong", detail: nil)
        }

        if let separator = trimmed.range(of: ": ") {
            let title = String(trimmed[..<separator.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detailRaw = String(trimmed[separator.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, !detailRaw.isEmpty, title.count <= 48 {
                return Parts(title: title, detail: humanizeDetail(detailRaw))
            }
        }

        return Parts(title: humanizeDetail(trimmed), detail: nil)
    }

    /// Soften framework noise (NIOSSH codes, etc.) into something a person can act on.
    static func humanizeDetail(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let lower = trimmed.lowercased()
        if lower.contains("niossh")
            || lower.contains("ssherror")
            || (lower.contains("channel") && lower.contains("error")) {
            return "Connection to the server was interrupted. Check the network and try again."
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return "The request timed out. Check the network and try again."
        }
        if lower.contains("not connected") || lower.contains("no route") {
            return "Not connected to the server. Reconnect and try again."
        }
        // Drop redundant "The operation couldn’t be completed." wrappers when we have a clearer core.
        if lower.hasPrefix("the operation couldn") {
            return "Something went wrong. Try again in a moment."
        }
        return trimmed
    }

    static func looksLikeLegacyLocalError(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let prefixes = [
            "Attachment upload failed",
            "Failed to stop OpenCode",
            "No active agent",
            "Cached file is no longer available",
            "Previous message is still processing",
            "Failed to answer OpenCode",
            "Failed to skip OpenCode",
            "Failed to get OpenCode",
            "OpenCode failed",
        ]
        return prefixes.contains { trimmed.hasPrefix($0) }
    }
}
