//
//  ProjectsView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//
//  Purpose: Display and manage remote projects
//

import SwiftUI
import SwiftData

struct ProjectsView: View {
    @State private var viewModel = ProjectsViewModel()
    @State private var showingSettings = false
    @State private var showingAddProject = false
    @StateObject private var serverManager = ServerManager.shared
    @StateObject private var projectContext = ProjectContext.shared
    
    @Query(sort: \RemoteProject.lastModified, order: .reverse) 
    private var projects: [RemoteProject]
    
    var body: some View {
        NavigationStack {
            List {
                if !projects.isEmpty {
                    ForEach(projects) { project in
                        ProjectRow(project: project)
                    }
                } else {
                    // Empty state
                    VStack(spacing: 16) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 50))
                            .foregroundColor(.secondary)
                        
                        Text("No Projects Yet")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text("Tap the + button to create your first project")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button {
                            showingAddProject = true
                        } label: {
                            Text("Create Project")
                                .font(.footnote)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddProject = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    SettingsView()
                }
            }
            .sheet(isPresented: $showingAddProject) {
                AddProjectSheet()
            }
        }
    }
}

struct ProjectRow: View {
    let project: RemoteProject
    @StateObject private var projectContext = ProjectContext.shared
    @State private var isActivating = false
    
    @Query private var servers: [Server]
    
    private var server: Server? {
        servers.first { $0.id == project.serverId }
    }
    
    var body: some View {
        Button {
            Task {
                await activateProject()
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    if let server = server {
                        Text("\(server.username)@\(server.host)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fontDesign(.monospaced)
                    }
                    
                    Text("Modified \(project.lastModified, style: .relative) ago")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if isActivating {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            .padding(.vertical, 4)
        }
        .disabled(isActivating)
        .opacity(isActivating ? 0.6 : 1.0)
    }
    
    private func activateProject() async {
        isActivating = true
        defer { isActivating = false }
        
        // Set the project as active
        projectContext.setActiveProject(project)
        
        // Navigation would typically be handled by the parent view
    }
}

struct AddProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var servers: [Server]
    
    @State private var projectName = ""
    @State private var selectedServer: Server?
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showError = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Project Details") {
                    TextField("Project Name", text: $projectName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    
                    Picker("Server", selection: $selectedServer) {
                        Text("Select a server").tag(nil as Server?)
                        ForEach(servers) { server in
                            Text(server.name).tag(server as Server?)
                        }
                    }
                }
                
                if let server = selectedServer {
                    Section("Project Location") {
                        HStack {
                            Text("Path:")
                                .foregroundColor(.secondary)
                            Text("/root/projects/\(projectName.isEmpty ? "[name]" : projectName)")
                                .fontDesign(.monospaced)
                                .font(.caption)
                        }
                        
                        HStack {
                            Text("Server:")
                                .foregroundColor(.secondary)
                            Text("\(server.username)@\(server.host)")
                                .fontDesign(.monospaced)
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await createProject()
                        }
                    }
                    .disabled(projectName.isEmpty || selectedServer == nil || isCreating)
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(errorMessage ?? "An error occurred")
            }
            .interactiveDismissDisabled(isCreating)
        }
    }
    
    private func createProject() async {
        guard let server = selectedServer else { return }
        
        isCreating = true
        defer { isCreating = false }
        
        do {
            // First, create the project folder on the server
            let projectService = ServiceManager.shared.projectService
            try await projectService.createProject(name: projectName, on: server)
            
            // Create and save the project locally
            let project = RemoteProject(name: projectName, serverId: server.id)
            modelContext.insert(project)
            
            try modelContext.save()
            
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

#Preview {
    ProjectsView()
}