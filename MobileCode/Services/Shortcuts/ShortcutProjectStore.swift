//
//  ShortcutProjectStore.swift
//  CodeAgentsMobile
//
//  Created by Codex on 2025-07-06.
//

import Foundation
import SwiftData

/// Metadata describing an agent that Shortcuts can run.
struct ShortcutProjectMetadata: Codable, Hashable, Identifiable {
    enum CodingKeys: String, CodingKey {
        case id
        case projectName
        case projectPath
        case serverId
        case serverName
        case serverHost
        case serverPort
        case serverUsername
        case authMethodType
        case sshKeyId
        case lastUpdated
    }
    
    let id: UUID
    let projectName: String
    let projectPath: String
    let serverId: UUID
    let serverName: String
    let serverHost: String
    let serverPort: Int
    let serverUsername: String
    let authMethodType: String
    let sshKeyId: UUID?
    let lastUpdated: Date
    
    init(
        id: UUID,
        projectName: String,
        projectPath: String,
        serverId: UUID,
        serverName: String,
        serverHost: String,
        serverPort: Int,
        serverUsername: String,
        authMethodType: String,
        sshKeyId: UUID?,
        lastUpdated: Date
    ) {
        self.id = id
        self.projectName = projectName
        self.projectPath = projectPath
        self.serverId = serverId
        self.serverName = serverName
        self.serverHost = serverHost
        self.serverPort = serverPort
        self.serverUsername = serverUsername
        self.authMethodType = authMethodType
        self.sshKeyId = sshKeyId
        self.lastUpdated = lastUpdated
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.projectName = try container.decodeIfPresent(String.self, forKey: .projectName) ?? "Unknown Agent"
        self.projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath) ?? "/"
        self.serverId = try container.decodeIfPresent(UUID.self, forKey: .serverId) ?? UUID()
        self.serverName = try container.decodeIfPresent(String.self, forKey: .serverName) ?? "Server"
        self.serverHost = try container.decodeIfPresent(String.self, forKey: .serverHost) ?? "localhost"
        self.serverPort = try container.decodeIfPresent(Int.self, forKey: .serverPort) ?? 22
        self.serverUsername = try container.decodeIfPresent(String.self, forKey: .serverUsername) ?? "root"
        self.authMethodType = try container.decodeIfPresent(String.self, forKey: .authMethodType) ?? "password"
        self.sshKeyId = try container.decodeIfPresent(UUID.self, forKey: .sshKeyId)
        self.lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated) ?? Date()
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(projectName, forKey: .projectName)
        try container.encode(projectPath, forKey: .projectPath)
        try container.encode(serverId, forKey: .serverId)
        try container.encode(serverName, forKey: .serverName)
        try container.encode(serverHost, forKey: .serverHost)
        try container.encode(serverPort, forKey: .serverPort)
        try container.encode(serverUsername, forKey: .serverUsername)
        try container.encode(authMethodType, forKey: .authMethodType)
        try container.encode(sshKeyId, forKey: .sshKeyId)
        try container.encode(lastUpdated, forKey: .lastUpdated)
    }
    
    var displayTitle: String {
        "\(projectName) • \(serverName)"
    }
    
    var subtitle: String {
        "\(serverUsername)@\(serverHost)"
    }
}

/// Handles persistence of shareable projects for App Shortcuts.
final class ShortcutProjectStore {
    private let storageKey = "shortcut_projects"
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    
    func loadProjects() -> [ShortcutProjectMetadata] {
        guard let data = AppGroup.sharedDefaults.data(forKey: storageKey) else {
            return []
        }
        
        do {
            return try decoder.decode([ShortcutProjectMetadata].self, from: data)
        } catch {
            print("⚠️ Failed to decode shortcut agent metadata: \(error). Clearing stale cache.")
            AppGroup.sharedDefaults.removeObject(forKey: storageKey)
            return []
        }
    }
    
    func saveProjects(_ projects: [ShortcutProjectMetadata]) {
        do {
            let data = try encoder.encode(projects)
            AppGroup.sharedDefaults.set(data, forKey: storageKey)
        } catch {
            print("⚠️ Failed to encode shortcut agent metadata: \(error)")
        }
    }
    
    func project(withId id: UUID) -> ShortcutProjectMetadata? {
        loadProjects().first { $0.id == id }
    }
}

/// Keeps shared metadata in sync with SwiftData models.
@MainActor
final class ShortcutSyncService {
    static let shared = ShortcutSyncService()
    
    private let store = ShortcutProjectStore()
    
    private init() {}
    
    func sync(using modelContext: ModelContext) {
        do {
            let projectDescriptor = FetchDescriptor<RemoteProject>()
            let serverDescriptor = FetchDescriptor<Server>()
            
            let projects = try modelContext.fetch(projectDescriptor)
            let servers = try modelContext.fetch(serverDescriptor)
            sync(projects: projects, servers: servers)
        } catch {
            print("⚠️ Failed to sync shortcut metadata: \(error)")
        }
    }
    
    func sync(projects: [RemoteProject], servers: [Server]) {
        let serverLookup = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        
        let shareableProjects = projects
            .compactMap { project -> ShortcutProjectMetadata? in
                guard let server = serverLookup[project.serverId] else { return nil }
                return ShortcutProjectMetadata(
                    id: project.id,
                    projectName: project.displayTitle,
                    projectPath: project.path,
                    serverId: server.id,
                    serverName: server.name,
                    serverHost: server.host,
                    serverPort: server.port,
                    serverUsername: server.username,
                    authMethodType: server.authMethodType,
                    sshKeyId: server.sshKeyId,
                    lastUpdated: Date()
                )
            }
        
        store.saveProjects(shareableProjects)
    }
    
    func removeProject(id: UUID) {
        var existing = store.loadProjects()
        existing.removeAll { $0.id == id }
        store.saveProjects(existing)
    }
}
