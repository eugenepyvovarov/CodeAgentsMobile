//
//  OpenCodePendingPermission.swift
//  CodeAgentsMobile
//
//  Purpose: Decodes OpenCode GET /permission list items (shape differs from permission.updated)
//

import Foundation

/// Pending permission from `GET /permission` (list payload; not live event properties).
struct OpenCodePendingPermission: Decodable, Identifiable {
    let id: String
    let sessionID: String?
    /// Stable permission type key (e.g. `external_directory`, `bash`).
    let permission: String?
    let patterns: [String]?
    let always: [String]?
    let metadata: [String: AnyCodable]?
    let tool: OpenCodePendingPermissionTool?

    struct OpenCodePendingPermissionTool: Decodable {
        let messageID: String?
        let callID: String?
    }

    /// Maps a list item into a chat `ToolApprovalRequest` using the stable permission type as `toolName`.
    func makeToolApprovalRequest(agentId: UUID) -> ToolApprovalRequest? {
        let permissionId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !permissionId.isEmpty else { return nil }

        let toolName = (permission?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "OpenCode Tool"

        var input: [String: Any] = [:]
        if let metadata {
            for (key, value) in metadata {
                input[key] = value.value
            }
        }
        if let patterns, !patterns.isEmpty {
            input["patterns"] = patterns
        }
        if let always, !always.isEmpty {
            input["always"] = always
        }
        if let callID = tool?.callID {
            input["callID"] = callID
        }
        if let messageID = tool?.messageID {
            input["messageID"] = messageID
        }

        let suggestions: [String]
        if let patterns, !patterns.isEmpty {
            suggestions = patterns
        } else if let always, !always.isEmpty {
            suggestions = always
        } else {
            suggestions = []
        }

        let blockedPath = Self.blockedPath(from: input)

        return ToolApprovalRequest(
            id: permissionId,
            toolName: toolName,
            input: input,
            suggestions: suggestions,
            blockedPath: blockedPath,
            agentId: agentId
        )
    }

    /// Session-scoped filter used by chat recovery.
    static func matchingSession(
        _ permissions: [OpenCodePendingPermission],
        sessionID: String
    ) -> [OpenCodePendingPermission] {
        let target = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return [] }
        return permissions.filter { item in
            guard let sid = item.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !sid.isEmpty else {
                return false
            }
            return sid == target
        }
    }

    private static func blockedPath(from input: [String: Any]) -> String? {
        if let directories = input["directories"] as? [String],
           let first = directories.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return first
        }
        if let directories = input["directories"] as? [Any] {
            for value in directories {
                if let path = value as? String, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return path
                }
            }
        }
        for key in ["path", "file", "file_path", "directory"] {
            if let path = input[key] as? String, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return path
            }
        }
        return nil
    }
}
