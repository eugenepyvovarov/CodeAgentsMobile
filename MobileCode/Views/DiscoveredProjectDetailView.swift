//
//  DiscoveredProjectDetailView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//
//  Purpose: Detail view for discovered remote projects
//  - Shows project metadata and structure
//  - Provides actions for opening in Claude, Terminal, File Browser
//  - Displays Git information and project statistics
//

import SwiftUI

struct DiscoveredProjectDetailView: View {
    let project: RemoteProject
    @StateObject private var connectionManager = ConnectionManager.shared
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                // Project Header
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: project.type.iconName)
                                .font(.title)
                                .foregroundColor(colorForProjectType(project.type.color))
                                .frame(width: 50, height: 50)
                                .background(Color(.systemGray5))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.name)
                                    .font(.title2)
                                    .fontWeight(.bold)
                                
                                Text(project.language)
                                    .font(.headline)
                                    .foregroundColor(colorForProjectType(project.type.color))
                                
                                if let framework = project.framework {
                                    Text(framework)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Spacer()
                            
                            if project.hasGit {
                                VStack(spacing: 4) {
                                    Image(systemName: "folder.badge.gearshape")
                                        .font(.title2)
                                        .foregroundColor(.orange)
                                    Text("Git")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                        
                        // Project path
                        HStack {
                            Image(systemName: "folder")
                                .foregroundColor(.secondary)
                            Text(project.path)
                                .font(.caption)
                                .fontDesign(.monospaced)
                                .foregroundColor(.secondary)
                        }
                        
                        // Last modified
                        HStack {
                            Image(systemName: "clock")
                                .foregroundColor(.secondary)
                            Text("Modified \(project.lastModified, style: .relative) ago")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }
                
                // Quick Actions
                Section("Actions") {
                    if connectionManager.isConnected {
                        NavigationLink(destination: ChatView()) {
                            Label("Open in Claude", systemImage: "message.fill")
                                .foregroundColor(.blue)
                        }
                        
                        NavigationLink(destination: TerminalView()) {
                            Label("Open Terminal", systemImage: "terminal.fill")
                                .foregroundColor(.green)
                        }
                        
                        NavigationLink(destination: FileBrowserView()) {
                            Label("Browse Files", systemImage: "folder.fill")
                                .foregroundColor(.orange)
                        }
                    } else {
                        HStack {
                            Image(systemName: "wifi.slash")
                                .foregroundColor(.red)
                            Text("Server connection required")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                // Project Information
                Section("Information") {
                    LabeledContent("Type", value: project.type.displayName)
                    LabeledContent("Language", value: project.language)
                    
                    if let framework = project.framework {
                        LabeledContent("Framework", value: framework)
                    }
                    
                    if let size = project.size {
                        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    
                    if let description = project.description {
                        LabeledContent("Description", value: description)
                    }
                }
                
                // Git Information
                if project.hasGit {
                    Section("Git Repository") {
                        HStack {
                            Image(systemName: "folder.badge.gearshape")
                                .foregroundColor(.orange)
                            Text("Git repository detected")
                                .foregroundColor(.primary)
                        }
                        
                        if let repoUrl = project.repositoryURL {
                            LabeledContent("Remote URL", value: repoUrl)
                        }
                        
                        Button {
                            // TODO: Implement git status check
                        } label: {
                            Label("Check Git Status", systemImage: "arrow.clockwise")
                        }
                        .disabled(!connectionManager.isConnected)
                    }
                }
                
                // Metadata
                if !project.metadata.isEmpty {
                    Section("Metadata") {
                        ForEach(Array(project.metadata.keys.sorted()), id: \.self) { key in
                            if let value = project.metadata[key] {
                                LabeledContent(key.capitalized, value: value)
                            }
                        }
                    }
                }
                
                // Server Information
                if let serverId = project.serverId,
                   let server = connectionManager.servers.first(where: { $0.id == serverId }) {
                    Section("Server") {
                        LabeledContent("Name", value: server.name)
                        LabeledContent("Host", value: "\(server.host):\(server.port)")
                        LabeledContent("Username", value: server.username)
                        
                        HStack {
                            Image(systemName: connectionManager.isConnected && connectionManager.activeServer?.id == serverId ? "circle.fill" : "circle")
                                .foregroundColor(connectionManager.isConnected && connectionManager.activeServer?.id == serverId ? .green : .gray)
                            Text(connectionManager.isConnected && connectionManager.activeServer?.id == serverId ? "Connected" : "Disconnected")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Project Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ConnectionStatusView()
                }
                
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            shareProject()
                        } label: {
                            Label("Share Project Info", systemImage: "square.and.arrow.up")
                        }
                        
                        if connectionManager.isConnected {
                            Button {
                                refreshProjectInfo()
                            } label: {
                                Label("Refresh Info", systemImage: "arrow.clockwise")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }
    
    private func colorForProjectType(_ colorName: String) -> Color {
        switch colorName {
        case "green": return .green
        case "blue": return .blue
        case "orange": return .orange
        case "red": return .red
        case "cyan": return .cyan
        case "purple": return .purple
        case "gray": return .gray
        default: return .primary
        }
    }
    
    private func shareProject() {
        let projectInfo = """
        Project: \(project.name)
        Type: \(project.type.displayName)
        Language: \(project.language)
        \(project.framework.map { "Framework: \($0)" } ?? "")
        Path: \(project.path)
        Git: \(project.hasGit ? "Yes" : "No")
        Last Modified: \(project.lastModified.formatted(date: .abbreviated, time: .shortened))
        """
        
        // TODO: Implement share sheet
        print("Sharing project info: \(projectInfo)")
    }
    
    private func refreshProjectInfo() {
        // TODO: Implement project info refresh
        print("Refreshing project info for: \(project.name)")
    }
}

#Preview {
    DiscoveredProjectDetailView(
        project: RemoteProject(
            name: "MobileApp",
            path: "/root/projects/MobileApp",
            type: .swift,
            language: "Swift",
            framework: "SwiftUI",
            hasGit: true,
            lastModified: Date().addingTimeInterval(-3600)
        )
    )
}