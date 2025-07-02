//
//  Project.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//
//  Purpose: Data models for project discovery and management
//  - Defines project types and metadata structures
//  - Supports remote project discovery via SSH
//  - Provides local caching for offline viewing
//

import Foundation
import SwiftData

/// Enumeration of supported project types with automatic detection
enum ProjectType: String, CaseIterable, Identifiable, Codable {
    case nodeJS = "nodejs"
    case python = "python"
    case swift = "swift"
    case rust = "rust"
    case go = "go"
    case java = "java"
    case cpp = "cpp"
    case ruby = "ruby"
    case php = "php"
    case docker = "docker"
    case unknown = "unknown"
    
    var id: String { rawValue }
    
    /// Human-readable display name for the project type
    var displayName: String {
        switch self {
        case .nodeJS: return "Node.js"
        case .python: return "Python"
        case .swift: return "Swift"
        case .rust: return "Rust"
        case .go: return "Go"
        case .java: return "Java"
        case .cpp: return "C++"
        case .ruby: return "Ruby"
        case .php: return "PHP"
        case .docker: return "Docker"
        case .unknown: return "Unknown"
        }
    }
    
    /// Icon name for the project type
    var iconName: String {
        switch self {
        case .nodeJS: return "dot.radiowaves.left.and.right"
        case .python: return "snake.fill"
        case .swift: return "swift"
        case .rust: return "gear.badge"
        case .go: return "go.forward"
        case .java: return "cup.and.saucer"
        case .cpp: return "terminal"
        case .ruby: return "diamond"
        case .php: return "globe"
        case .docker: return "shippingbox"
        case .unknown: return "questionmark.folder"
        }
    }
    
    /// Color associated with the project type
    var color: String {
        switch self {
        case .nodeJS: return "green"
        case .python: return "blue"
        case .swift: return "orange"
        case .rust: return "red"
        case .go: return "cyan"
        case .java: return "red"
        case .cpp: return "gray"
        case .ruby: return "red"
        case .php: return "purple"
        case .docker: return "blue"
        case .unknown: return "gray"
        }
    }
}

/// Represents a project discovered on a remote server
struct RemoteProject: Identifiable, Codable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let type: ProjectType
    let language: String
    let framework: String?
    let hasGit: Bool
    let lastModified: Date
    
    /// Server ID where this project was discovered
    var serverId: UUID?
    
    /// Repository URL if Git is detected
    var repositoryURL: String?
    
    /// Project description extracted from README or package files
    var description: String?
    
    /// Size of the project directory in bytes
    var size: Int64?
    
    /// Additional metadata specific to project type
    var metadata: [String: String] = [:]
    
    init(name: String, 
         path: String, 
         type: ProjectType, 
         language: String, 
         framework: String? = nil, 
         hasGit: Bool = false, 
         lastModified: Date = Date()) {
        self.name = name
        self.path = path
        self.type = type
        self.language = language
        self.framework = framework
        self.hasGit = hasGit
        self.lastModified = lastModified
    }
}

/// Local cached representation of a remote project
class CachedProject: Codable {
    let id = UUID()
    let remoteProject: RemoteProject
    let cachedAt: Date
    let serverId: UUID
    
    /// Whether the project files have been synced locally
    var isFullyCached: Bool = false
    
    /// Local cache directory path
    var localCachePath: String?
    
    /// Last sync timestamp
    var lastSyncDate: Date?
    
    /// Cached file structure for offline viewing
    var cachedFiles: [CachedFile] = []
    
    init(remoteProject: RemoteProject, serverId: UUID) {
        self.remoteProject = remoteProject
        self.serverId = serverId
        self.cachedAt = Date()
    }
    
    /// Check if the cached project is still valid (not too old)
    var isValid: Bool {
        let expirationTime: TimeInterval = 3600 // 1 hour
        return Date().timeIntervalSince(cachedAt) < expirationTime
    }
}

/// Represents a cached file from a remote project
struct CachedFile: Codable, Identifiable {
    let id = UUID()
    let name: String
    let relativePath: String
    let isDirectory: Bool
    let size: Int64?
    let modificationDate: Date?
    let content: Data?
    
    /// Whether this file has been downloaded and cached locally
    var isCached: Bool {
        return content != nil
    }
}

/// Manager for handling project discovery and caching
@MainActor
class ProjectManager: ObservableObject {
    static let shared = ProjectManager()
    
    @Published var discoveredProjects: [RemoteProject] = []
    @Published var isDiscovering = false
    @Published var lastDiscoveryDate: Date?
    
    private var cachedProjects: [UUID: CachedProject] = [:]
    private let cacheDirectory: URL
    
    private init() {
        // Set up cache directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        cacheDirectory = documentsPath.appendingPathComponent("ProjectCache")
        
        // Create cache directory if it doesn't exist
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // Load cached projects
        loadCachedProjects()
    }
    
    /// Discover projects on the currently connected server
    func discoverProjects() async {
        guard let activeServer = ConnectionManager.shared.activeServer else {
            print("❌ No active server connection for project discovery")
            return
        }
        
        isDiscovering = true
        
        do {
            let sshService = ServiceManager.shared.sshService
            
            // Connect to the server if not already connected
            let session = try await sshService.connect(to: activeServer)
            
            // Discover projects using the session
            let projects = try await session.discoverProjects()
            
            // Update projects with server ID
            var updatedProjects = projects
            for i in 0..<updatedProjects.count {
                updatedProjects[i].serverId = activeServer.id
            }
            
            discoveredProjects = updatedProjects
            lastDiscoveryDate = Date()
            
            // Cache the discovered projects
            cacheProjects(updatedProjects, for: activeServer.id)
            
            print("✅ Discovered \(projects.count) projects on \(activeServer.name)")
            
        } catch {
            print("❌ Failed to discover projects: \(error.localizedDescription)")
        }
        
        isDiscovering = false
    }
    
    /// Get projects for a specific server (from cache if available)
    func getProjects(for serverId: UUID) -> [RemoteProject] {
        return discoveredProjects.filter { $0.serverId == serverId }
    }
    
    /// Cache projects locally
    private func cacheProjects(_ projects: [RemoteProject], for serverId: UUID) {
        for project in projects {
            let cachedProject = CachedProject(remoteProject: project, serverId: serverId)
            cachedProjects[project.id] = cachedProject
        }
        saveCachedProjects()
    }
    
    /// Load cached projects from disk
    private func loadCachedProjects() {
        let cacheFile = cacheDirectory.appendingPathComponent("projects.json")
        
        guard let data = try? Data(contentsOf: cacheFile),
              let projects = try? JSONDecoder().decode([UUID: CachedProject].self, from: data) else {
            return
        }
        
        cachedProjects = projects
        
        // Load valid cached projects into discoveredProjects
        let validProjects = cachedProjects.values
            .filter { $0.isValid }
            .map { $0.remoteProject }
        
        discoveredProjects = Array(validProjects)
    }
    
    /// Save cached projects to disk
    private func saveCachedProjects() {
        let cacheFile = cacheDirectory.appendingPathComponent("projects.json")
        
        do {
            let data = try JSONEncoder().encode(cachedProjects)
            try data.write(to: cacheFile)
        } catch {
            print("❌ Failed to save cached projects: \(error.localizedDescription)")
        }
    }
    
    /// Clear cached projects for a specific server
    func clearCache(for serverId: UUID) {
        cachedProjects = cachedProjects.filter { _, project in
            project.serverId != serverId
        }
        saveCachedProjects()
        
        // Remove from discovered projects
        discoveredProjects = discoveredProjects.filter { $0.serverId != serverId }
    }
    
    /// Clear all cached projects
    func clearAllCache() {
        cachedProjects.removeAll()
        discoveredProjects.removeAll()
        saveCachedProjects()
        
        // Clear cache directory
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    /// Create a new project directory on the server
    /// - Parameter name: Name of the project
    func createProject(name: String) async {
        guard let activeServer = ConnectionManager.shared.activeServer else {
            print("❌ No active server connection for project creation")
            return
        }
        
        do {
            let sshService = ServiceManager.shared.sshService
            let session = try await sshService.connect(to: activeServer)
            
            let projectPath = "/root/projects/\(name)"
            
            // Create project directory
            _ = try await session.execute("mkdir -p '\(projectPath)'")
            
            print("✅ Created project '\(name)' at \(projectPath)")
            
            // Refresh projects list
            await discoverProjects()
            
        } catch {
            print("❌ Failed to create project: \(error.localizedDescription)")
        }
    }
    
}

// MARK: - Legacy SwiftData Project Model (for compatibility)

@Model
final class Project {
    var id = UUID()
    var name: String
    var path: String
    var serverId: UUID
    var lastAccessed: Date = Date()
    var lastOpened: Date?
    var language: String?
    var gitRemote: String?
    var isFavorite: Bool = false
    
    init(name: String, path: String, serverId: UUID, language: String? = nil) {
        self.name = name
        self.path = path
        self.serverId = serverId
        self.language = language
    }
    
    var languageIcon: String {
        switch language?.lowercased() {
        case "swift": return "swift"
        case "python": return "🐍"
        case "javascript": return "JS"
        case "typescript": return "TS"
        case "go": return "Go"
        case "rust": return "🦀"
        default: return "📁"
        }
    }
}