//
//  ActiveProjectView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-01.
//
//  Purpose: Shows the active project's details and quick actions
//  - Displays project information
//  - Shows quick action buttons for Claude, Terminal, Files
//  - Allows switching to different project or disconnecting
//

import SwiftUI
import SwiftData

struct ActiveProjectView: View {
    let project: Project
    @StateObject private var projectContext = ProjectContext.shared
    @StateObject private var connectionManager = ConnectionManager.shared
    @State private var showingProjectPicker = false
    
    var body: some View {
        VStack(spacing: 20) {
            // Quick Actions
            VStack(spacing: 12) {
                NavigationLink {
                    ChatView()
                } label: {
                    HStack {
                        Image(systemName: "message.fill")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open Claude Chat")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text("Start coding with Claude")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                
                NavigationLink {
                    FileBrowserView()
                } label: {
                    HStack {
                        Image(systemName: "folder.fill")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Browse Files")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text("View and edit project files")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                
                NavigationLink {
                    TerminalView()
                } label: {
                    HStack {
                        Image(systemName: "terminal.fill")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open Terminal")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text("Run commands in project directory")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            
            Spacer()
            
            // Switch Project or Disconnect
            VStack(spacing: 12) {
                Button {
                    showingProjectPicker = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.swap")
                        Text("Switch Project")
                    }
                    .font(.footnote)
                    .foregroundColor(.blue)
                }
                
                Button {
                    projectContext.clearActiveProject()
                } label: {
                    HStack {
                        Image(systemName: "arrow.backward.circle")
                        Text("Back to Projects")
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .navigationTitle("Project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ConnectionStatusView()
            }
        }
        .sheet(isPresented: $showingProjectPicker) {
            ProjectPickerSheet()
        }
    }
}

struct ProjectPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var projectManager = ProjectManager.shared
    @StateObject private var connectionManager = ConnectionManager.shared
    @StateObject private var projectContext = ProjectContext.shared
    @State private var searchText = ""
    
    var discoveredProjects: [RemoteProject] {
        if let activeServer = connectionManager.activeServer {
            return projectManager.getProjects(for: activeServer.id)
        }
        return []
    }
    
    var filteredProjects: [RemoteProject] {
        if searchText.isEmpty {
            return discoveredProjects
        } else {
            return discoveredProjects.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    var body: some View {
        NavigationStack {
            List(filteredProjects) { project in
                Button {
                    Task {
                        // Use same activation logic as DiscoveredProjectRow
                        await activateProject(project)
                        dismiss()
                    }
                } label: {
                    HStack {
                        Image(systemName: project.type.iconName)
                            .font(.title3)
                            .foregroundColor(.blue)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name)
                                .font(.headline)
                                .foregroundColor(.primary)
                            
                            Text(project.path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fontDesign(.monospaced)
                        }
                        
                        Spacer()
                        
                        if projectContext.activeProject?.path == project.path {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .searchable(text: $searchText, prompt: "Search projects")
            .navigationTitle("Switch Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func activateProject(_ project: RemoteProject) async {
        guard let serverId = project.serverId else { return }
        
        // Find or create the Project model
        guard let modelContext = try? ModelContext(ModelContainer(for: Project.self)) else { return }
        
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { proj in
                proj.path == project.path && proj.serverId == serverId
            }
        )
        
        do {
            let existingProjects = try modelContext.fetch(descriptor)
            let projectModel: Project
            
            if let existing = existingProjects.first {
                projectModel = existing
            } else {
                // Create new Project model from RemoteProject
                projectModel = Project(
                    name: project.name,
                    path: project.path,
                    serverId: serverId,
                    language: project.language
                )
                projectModel.gitRemote = project.repositoryURL
                modelContext.insert(projectModel)
                try modelContext.save()
            }
            
            // Configure ProjectContext with model context if needed
            projectContext.configure(with: modelContext)
            
            // Activate the project
            await projectContext.setActiveProject(projectModel)
            
        } catch {
            print("❌ Failed to activate project: \(error)")
        }
    }
}

#Preview {
    NavigationStack {
        ActiveProjectView(
            project: Project(
                name: "Sample Project",
                path: "/root/projects/sample",
                serverId: UUID(),
                language: "Swift"
            )
        )
    }
}