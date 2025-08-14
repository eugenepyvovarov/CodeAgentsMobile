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
            VStack(spacing: 0) {
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
                
                // Add new project button at the bottom (only when projects exist)
                if !projects.isEmpty {
                    Button {
                        showingAddProject = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Create Project")
                        }
                        .font(.body)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .padding()
                }
            }
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
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
    
    let preselectedServer: Server?
    let onProjectCreated: (() -> Void)?
    let onSkip: (() -> Void)?
    
    @State private var projectName = ""
    @State private var selectedServer: Server?
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showingAddServer = false
    @State private var isDetectingPath = false
    @State private var detectedPath: String?
    @State private var customPath: String?
    @State private var showingFolderPicker = false
    
    init(preselectedServer: Server? = nil, onProjectCreated: (() -> Void)? = nil, onSkip: (() -> Void)? = nil) {
        self.preselectedServer = preselectedServer
        self.onProjectCreated = onProjectCreated
        self.onSkip = onSkip
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Project Details") {
                    TextField("Project Name", text: $projectName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    
                    Menu {
                        ForEach(servers) { server in
                            Button {
                                selectedServer = server
                                detectedPath = nil // Reset detected path when changing servers
                                customPath = nil // Reset custom path when changing servers
                                Task {
                                    await detectProjectPath(for: server)
                                }
                            } label: {
                                HStack {
                                    Text(server.name)
                                    if !server.cloudInitComplete && server.providerId != nil {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .foregroundColor(.orange)
                                    }
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
                    // Show warning if server cloud-init is not complete
                    if !server.cloudInitComplete && server.providerId != nil {
                        Section {
                            HStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.title2)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Server Still Configuring")
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    
                                    Text("This server is still installing Claude Code. Creating a project now may fail.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    
                                    HStack(spacing: 4) {
                                        Text("Status:")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        CloudInitStatusBadge(status: server.cloudInitStatus)
                                    }
                                }
                                
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    
                    Section("Project Location") {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Path:")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                                if isDetectingPath {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                } else {
                                    let effectivePath = customPath ?? server.lastUsedProjectPath ?? detectedPath ?? server.defaultProjectsPath ?? "/root/projects"
                                    Text("\(effectivePath)/\(projectName.isEmpty ? "[name]" : projectName)")
                                        .fontDesign(.monospaced)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            Spacer()
                            Button("Change") {
                                showingFolderPicker = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isDetectingPath)
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
                    // Show "Skip" when coming from server creation, "Cancel" otherwise
                    Button(preselectedServer != nil && onSkip != nil ? "Skip" : "Cancel") {
                        if let onSkip = onSkip, preselectedServer != nil {
                            // If we have a skip handler and a preselected server,
                            // call the skip handler to dismiss entire navigation chain
                            onSkip()
                        }
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
            .onAppear {
                // If we have a preselected server, use it
                if let preselectedServer = preselectedServer {
                    selectedServer = preselectedServer
                    Task {
                        await detectProjectPath(for: preselectedServer)
                    }
                }
            }
            .sheet(isPresented: $showingAddServer) {
                AddServerSheet { newServer in
                    // When a new server is added, automatically select it
                    selectedServer = newServer
                    detectedPath = nil // Reset detected path
                    customPath = nil // Reset custom path
                    Task {
                        await detectProjectPath(for: newServer)
                    }
                }
            }
            .sheet(isPresented: $showingFolderPicker) {
                if let server = selectedServer {
                    let effectivePath = customPath ?? server.lastUsedProjectPath ?? detectedPath ?? server.defaultProjectsPath ?? "/root/projects"
                    FolderPickerView(
                        server: server,
                        initialPath: effectivePath,
                        onSelect: { path in
                            customPath = path
                        }
                    )
                }
            }
        }
    }
    
    private func createProject() async {
        guard let server = selectedServer else { return }
        
        isCreating = true
        defer { isCreating = false }
        
        do {
            // Determine the effective path
            let effectivePath = customPath ?? server.lastUsedProjectPath ?? detectedPath ?? server.defaultProjectsPath ?? "/root/projects"
            
            // First, create the project folder on the server
            let projectService = ServiceManager.shared.projectService
            try await projectService.createProject(name: projectName, on: server, customPath: effectivePath)
            
            // If a custom path was used, save it to the server
            if let customPath = customPath {
                server.lastUsedProjectPath = customPath
            }
            
            // Create and save the project locally
            let project = RemoteProject(name: projectName, serverId: server.id, basePath: effectivePath)
            modelContext.insert(project)
            
            try modelContext.save()
            
            // Call the completion handler if provided
            if let onProjectCreated = onProjectCreated {
                onProjectCreated()
            } else {
                // Otherwise just dismiss normally
                dismiss()
            }
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