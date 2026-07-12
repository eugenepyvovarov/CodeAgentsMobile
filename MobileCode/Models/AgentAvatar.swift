//
//  AgentAvatar.swift
//  CodeAgentsMobile
//
//  Purpose: Agent avatar kinds stored in .codeagents/codeagents.json (+ optional image file).
//

import Foundation

enum AgentAvatarKind: String, Codable, Sendable, Equatable {
    case none
    case emoji
    case image
}

enum AgentAvatarUpdatedBy: String, Codable, Sendable, Equatable {
    case user
    case mcp
}

/// Avatar metadata embedded under `avatar` in codeagents.json.
struct AgentAvatarDescriptor: Codable, Equatable, Sendable {
    var kind: AgentAvatarKind
    var emoji: String?
    /// Project-relative path to image bytes (e.g. `.codeagents/avatar.png`).
    var image: String?
    var updatedAt: Date?
    var updatedBy: AgentAvatarUpdatedBy?

    enum CodingKeys: String, CodingKey {
        case kind
        case emoji
        case image
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
    }

    static let empty = AgentAvatarDescriptor(kind: .none, emoji: nil, image: nil, updatedAt: nil, updatedBy: nil)

    var isVisible: Bool {
        switch kind {
        case .none:
            return false
        case .emoji:
            return !(emoji?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        case .image:
            return !(image?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }
}

/// Full identity document at `.codeagents/codeagents.json`.
struct CodeAgentsIdentityDocument: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var agentId: String
    var avatar: AgentAvatarDescriptor?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case agentId = "agent_id"
        case avatar
    }

    static let currentSchemaVersion = 2

    init(schemaVersion: Int = currentSchemaVersion, agentId: String, avatar: AgentAvatarDescriptor? = nil) {
        self.schemaVersion = schemaVersion
        self.agentId = agentId
        self.avatar = avatar
    }

    /// Decode leniently: missing avatar is fine; empty agent_id rejected by callers.
    static func decode(from data: Data) throws -> CodeAgentsIdentityDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CodeAgentsIdentityDocument.self, from: data)
    }

    func encodeJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var payload = self
        if payload.schemaVersion < Self.currentSchemaVersion {
            payload.schemaVersion = Self.currentSchemaVersion
        }
        var data = try encoder.encode(payload)
        if let newline = "\n".data(using: .utf8) {
            data.append(newline)
        }
        return data
    }
}

enum AgentAvatarPathValidation {
    /// Reject absolute paths, `~`, and `..` / `.` segments. Returns normalized relative path.
    static func validatedProjectRelativePath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return nil
        }
        let parts = trimmed.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }
        if parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) {
            return nil
        }
        return parts.joined(separator: "/")
    }

    static func isAllowedImageExtension(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "webp", "gif"].contains(ext)
    }
}
