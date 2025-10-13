//
//  ProjectAppEntity.swift
//  CodeAgentsMobile
//
//  Created by Codex on 2025-07-06.
//

import AppIntents

/// App Intents representation of a shareable CodeAgents project.
struct ProjectAppEntity: AppEntity, Identifiable, Hashable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(
        name: "CodeAgents Project"
    )
    
    static var defaultQuery = ProjectQuery()
    
    let metadata: ShortcutProjectMetadata
    
    var id: UUID { metadata.id }
    
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: metadata.projectName),
            subtitle: LocalizedStringResource(stringLiteral: metadata.subtitle)
        )
    }
    
    init(metadata: ShortcutProjectMetadata) {
        self.metadata = metadata
    }
}

/// Provides project entities to the Shortcuts picker.
struct ProjectQuery: EntityQuery {
    func entities(for identifiers: [ProjectAppEntity.ID]) async throws -> [ProjectAppEntity] {
        let store = ShortcutProjectStore()
        let projects = store.loadProjects()
        let map = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, ProjectAppEntity(metadata: $0)) })
        return identifiers.compactMap { map[$0] }
    }
    
    func suggestedEntities() async throws -> [ProjectAppEntity] {
        ShortcutProjectStore()
            .loadProjects()
            .sorted { $0.projectName.localizedCaseInsensitiveCompare($1.projectName) == .orderedAscending }
            .map(ProjectAppEntity.init)
    }
    
    func defaultResult() -> ProjectAppEntity? {
        guard let metadata = ShortcutProjectStore().loadProjects().first else {
            return nil
        }
        return ProjectAppEntity(metadata: metadata)
    }
}

extension ProjectAppEntity {
    static let placeholder = ProjectAppEntity(metadata: .placeholder)
}

extension ShortcutProjectMetadata {
    static let placeholder = ShortcutProjectMetadata(
        id: UUID(),
        projectName: "Sample Project",
        projectPath: "/root/projects/sample-project",
        serverId: UUID(),
        serverName: "Demo Server",
        serverHost: "example.com",
        serverPort: 22,
        serverUsername: "root",
        authMethodType: "password",
        sshKeyId: nil,
        lastUpdated: Date()
    )
}
