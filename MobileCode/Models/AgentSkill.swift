//
//  AgentSkill.swift
//  CodeAgentsMobile
//
//  Purpose: Models for global agent skills and per-agent selections
//

import Foundation
import SwiftData

enum AgentSkillSource: String, Codable, CaseIterable {
    case marketplace
    case github
    case unknown
}

@Model
final class AgentSkill {
    var id: UUID
    var slug: String
    var name: String
    var summary: String?
    var author: String?
    var source: AgentSkillSource
    var sourceReference: String
    var createdAt: Date
    var updatedAt: Date

    init(slug: String,
         name: String,
         summary: String? = nil,
         author: String? = nil,
         source: AgentSkillSource = .unknown,
         sourceReference: String = "",
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = UUID()
        self.slug = slug
        self.name = name
        self.summary = summary
        self.author = author
        self.source = source
        self.sourceReference = sourceReference
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func markUpdated() {
        updatedAt = Date()
    }
}

@Model
final class AgentSkillAssignment {
    var id: UUID
    var projectId: UUID
    var skillSlug: String
    var createdAt: Date

    init(projectId: UUID, skillSlug: String, createdAt: Date = Date()) {
        self.id = UUID()
        self.projectId = projectId
        self.skillSlug = skillSlug
        self.createdAt = createdAt
    }
}

@Model
final class SkillMarketplaceSource {
    var id: UUID
    var owner: String
    var repo: String
    var displayName: String
    var createdAt: Date
    var updatedAt: Date

    init(owner: String,
         repo: String,
         displayName: String,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = UUID()
        self.owner = owner
        self.repo = repo
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var normalizedKey: String {
        "\(owner)/\(repo)".lowercased()
    }

    func rename(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != displayName else { return }
        displayName = trimmed
        markUpdated()
    }

    func markUpdated() {
        updatedAt = Date()
    }
}
