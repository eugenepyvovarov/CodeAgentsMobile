//
//  AgentEnvironmentVariable.swift
//  CodeAgentsMobile
//
//  Purpose: Per-agent environment variables (name/value) cached locally
//

import Foundation
import SwiftData

@Model
final class AgentEnvironmentVariable {
    var id: UUID
    var projectId: UUID
    var key: String
    var value: String
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(projectId: UUID,
         key: String,
         value: String,
         isEnabled: Bool = true,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = UUID()
        self.projectId = projectId
        self.key = key
        self.value = value
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func markUpdated() {
        updatedAt = Date()
    }
}

