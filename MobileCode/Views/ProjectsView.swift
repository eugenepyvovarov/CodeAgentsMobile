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
    @State private var projectToDelete: RemoteProject?
    @State private var deleteFromServer = false
    @StateObject private var serverManager = ServerManager.shared
    @StateObject private var projectContext = ProjectContext.shared
    @Environment(\.modelContext) private var modelContext
    
    @Query(sort: \RemoteProject.lastModified, order: .reverse) 
    private var projects: [RemoteProject]
    
    var body: some View {
        NavigationStack {
            List {
                if !projects.isEmpty {
                    ForEach(projects) { project in
                        ProjectRow(project: project)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    projectToDelete = project
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
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
            .sheet(item: $projectToDelete) { project in
                DeleteProjectConfirmationSheet(
                    project: project,
                    deleteFromServer: $deleteFromServer,
                    onDelete: {
                        Task {
                            await performDeletion(of: project)
                        }
                    },
                    onCancel: {
                        projectToDelete = nil
                        deleteFromServer = false
                    }
                )
            }
        }
    }
    
    // MARK: - Delete Methods
    
    private func performDeletion(of project: RemoteProject) async {
        do {
            // If deleteFromServer is true, delete from server first
            if deleteFromServer {
                try await ServiceManager.shared.projectService.deleteProject(project)
            }
            
            // Delete locally
            modelContext.delete(project)
            try modelContext.save()
            
            // Clear selection and reset state
            projectToDelete = nil
            deleteFromServer = false
            
        } catch {
            // Failed to delete project
            // TODO: Show error alert
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
    @State private var showingAddServer = false
    @State private var isDetectingPath = false
    @State private var detectedPath: String?
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Project Details") {
                    TextField("Project Name", text: $projectName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    
                    Menu {
                        ForEach(servers) { server in
                            Button(server.name) {
                                selectedServer = server
                                detectedPath = nil // Reset detected path when changing servers
                                Task {
                                    await detectProjectPath(for: server)
                                }
                            }
                        }
                        
                        Divider()
                        
                        Button {
                            showingAddServer = true
                        } label: {
                            Label("Add New Server", systemImage: "plus.circle")
                        }
                    } label: {
                        HStack {
                            Text("Server")
                            Spacer()
                            if isDetectingPath {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Text(selectedServer?.name ?? "Select a server")
                                    .foregroundColor(selectedServer == nil ? .secondary : .primary)
                            }
                        }
                    }
                    .disabled(isDetectingPath)
                }
                
                if let server = selectedServer {
                    Section("Project Location") {
                        HStack {
                            Text("Path:")
                                .foregroundColor(.secondary)
                            if isDetectingPath {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                let basePath = detectedPath ?? server.defaultProjectsPath ?? "/root/projects"
                                Text("\(basePath)/\(projectName.isEmpty ? "[name]" : projectName)")
                                    .fontDesign(.monospaced)
                                    .font(.caption)
                            }
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
            .sheet(isPresented: $showingAddServer) {
                AddServerSheet { newServer in
                    // When a new server is added, automatically select it
                    selectedServer = newServer
                    detectedPath = nil // Reset detected path
                    Task {
                        await detectProjectPath(for: newServer)
                    }
                }
            }
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
            let basePath = detectedPath ?? server.defaultProjectsPath ?? "/root/projects"
            let project = RemoteProject(name: projectName, serverId: server.id, basePath: basePath)
            modelContext.insert(project)
            
            try modelContext.save()
            
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
    
    private func detectProjectPath(for server: Server) async {
        // If already detected, just use the cached value
        if let existingPath = server.defaultProjectsPath {
            detectedPath = existingPath
            return
        }
        
        isDetectingPath = true
        defer { isDetectingPath = false }
        
        do {
            // Connect to the server and detect home directory
            let sshService = ServiceManager.shared.sshService
            let session = try await sshService.connect(to: server)
            
            if let swiftSHSession = session as? SwiftSHSession {
                try await swiftSHSession.ensureDefaultProjectsPath()
                
                // Update our local state immediately
                detectedPath = server.defaultProjectsPath
                
                // Save the updated server
                try modelContext.save()
            }
        } catch {
            // If detection fails, we'll just use the default
            SSHLogger.log("Failed to detect project path: \(error)", level: .warning)
            detectedPath = "/root/projects" // Explicitly set the fallback
        }
    }
}


struct DeleteProjectConfirmationSheet: View {
    let project: RemoteProject
    @Binding var deleteFromServer: Bool
    let onDelete: () -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Are you sure you want to delete '\(project.name)'?")
                        .font(.body)
                    
                    Toggle("Also delete from server", isOn: $deleteFromServer)
                        .tint(.red)
                    
                    if deleteFromServer {
                        Label {
                            Text("The project folder and all its contents will be permanently deleted from the server.")
                        } icon: {
                            Image(systemName: "server.rack")
                                .foregroundColor(.red)
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        
                        Label {
                            Text("This action cannot be undone.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                        }
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    } else {
                        Label {
                            Text("The project will only be removed from this app. Files on the server will remain intact.")
                        } icon: {
                            Image(systemName: "iphone")
                                .foregroundColor(.blue)
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Delete Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete", role: .destructive) {
                        dismiss()
                        onDelete()
                    }
                    .foregroundColor(.red)
                }
            }
        }
        .presentationDetents([.height(300)])
    }
}

#Preview {
    ProjectsView()
}