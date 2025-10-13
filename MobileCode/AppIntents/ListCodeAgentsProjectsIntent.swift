//
//  ListCodeAgentsProjectsIntent.swift
//  CodeAgentsMobile
//
//  Created by Codex on 2025-10-11.
//

import AppIntents
import SwiftData

struct ListCodeAgentsProjectsIntent: AppIntent {
    static var title: LocalizedStringResource = "List CodeAgents Projects"
    static var description = IntentDescription(
        "Return all projects that are available in CodeAgents along with their server information."
    )
    
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let context = await ShortcutPersistenceController.shared.makeContext()
        
        let projectDescriptor = FetchDescriptor<RemoteProject>()
        let serverDescriptor = FetchDescriptor<Server>()
        
        let projects = try context.fetch(projectDescriptor)
        let servers = try context.fetch(serverDescriptor)
        let serverMap = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        
        let summaries = projects.map { project -> String in
            if let server = serverMap[project.serverId] {
                return "\(project.name) — \(server.username)@\(server.host)"
            } else {
                return "\(project.name) — server unavailable"
            }
        }.sorted()
        
        return .result(value: summaries)
    }
}
