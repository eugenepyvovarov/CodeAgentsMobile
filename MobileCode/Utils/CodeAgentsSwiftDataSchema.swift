//
//  CodeAgentsSwiftDataSchema.swift
//  CodeAgentsMobile
//
//  Created by Codex on 2026-01-31.
//

import SwiftData

enum CodeAgentsSwiftDataSchema {
    static let schema = Schema([
        RemoteProject.self,
        Server.self,
        Message.self,
        SSHKey.self,
        ServerProvider.self,
        AgentSkill.self,
        AgentSkillAssignment.self,
        SkillMarketplaceSource.self,
        AgentScheduledTask.self,
        AgentEnvironmentVariable.self
    ])
}

