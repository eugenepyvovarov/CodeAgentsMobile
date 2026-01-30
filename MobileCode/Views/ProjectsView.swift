//
//  ProjectsView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//
//  Purpose: Display and manage remote agents
//

import SwiftUI
import SwiftData

struct ProjectsView: View {
    @State private var viewModel = ProjectsViewModel()
    @State private var showingSettings = false
    @State private var showingAddProject = false
    @State private var projectToDelete: RemoteProject?
    @State private var projectToEdit: RemoteProject?
    @State private var deleteFromServer = false
    @State private var editMode: EditMode = .inactive
    @StateObject private var serverManager = ServerManager.shared
    @StateObject private var projectContext = ProjectContext.shared
    @Environment(\.modelContext) private var modelContext
    
    @Query(sort: \RemoteProject.lastModified, order: .reverse) 
    private var projects: [RemoteProject]
    
    private var isEditing: Bool {
        editMode.isEditing
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    if !projects.isEmpty {
                        ForEach(projects) { project in
                            if isEditing {
                                ProjectRow(
                                    project: project,
                                    isEditing: true,
                                    onEdit: { projectToEdit = project },
                                    onDelete: { projectToDelete = project }
                                )
                            } else {
                                ProjectRow(project: project)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button {
                                            projectToEdit = project
                                        } label: {
                                            Label("Rename", systemImage: "pencil")
                                        }
                                        .tint(.blue)

                                        Button {
                                            projectToDelete = project
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                        .tint(.red)
                                    }
                            }
                        }
                    } else {
                    // Empty state
                    VStack(spacing: 16) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 50))
                            .foregroundColor(.secondary)
                        
                        Text("No Agents Yet")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Button {
                            showingAddProject = true
                        } label: {
                            Text("Create Agent")
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
                
                // Add new agent button at the bottom (only when projects exist)
                if !projects.isEmpty {
                    Button {
                        showingAddProject = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Create Agent")
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
            .navigationTitle("Agents")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !projects.isEmpty {
                        EditButton()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    SettingsView()
                }
            }
            .sheet(isPresented: $showingAddProject) {
                AddProjectSheet()
            }
            .sheet(item: $projectToEdit) { project in
                EditProjectSheet(project: project)
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
            ShortcutSyncService.shared.sync(using: modelContext)
            
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
    var isEditing: Bool = false
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    @StateObject private var projectContext = ProjectContext.shared
    @State private var isActivating = false
    
    @Query private var servers: [Server]
    
    private var server: Server? {
        servers.first { $0.id == project.serverId }
    }
    
    var body: some View {
        Group {
            if isEditing {
                HStack {
                    leftColumn
                    Spacer()
                    activationIndicator
                    actionButtons
                }
                .padding(.vertical, 4)
            } else {
                Button {
                    Task {
                        await activateProject()
                    }
                } label: {
                    HStack {
                        leftColumn
                        Spacer()
                        activationIndicator
                    }
                    .padding(.vertical, 4)
                }
                .disabled(isActivating)
                .opacity(isActivating ? 0.6 : 1.0)
            }
        }
    }
    
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.displayTitle)
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
    }
    
    @ViewBuilder
    private var activationIndicator: some View {
        if isActivating {
            ProgressView()
                .scaleEffect(0.8)
        }
    }
    
    private var actionButtons: some View {
        HStack(spacing: 12) {
            if let onEdit {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("Edit Agent")
            }
            
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete Agent")
            }
        }
        .buttonStyle(.borderless)
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
    @State private var projectDisplayName = ""
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
                Section("Agent Details") {
                    TextField("Agent Name", text: $projectDisplayName)
                        .textInputAutocapitalization(.words)

                    Text("Shown in the app. Leave blank to use the folder name.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
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
                                    
                                    Text("This server is still installing Claude Code. Creating an agent now may fail.")
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
                    
                    Section("Agent Folder") {
                        TextField("Folder Name", text: $projectName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

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
                                    Text("\(effectivePath)/\(folderNamePreview)")
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
            .navigationTitle("New Agent")
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
                    .disabled(!canCreate)
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
    
    private var trimmedFolderName: String {
        projectName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDisplayName: String {
        projectDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resolvedFolderName: String {
        trimmedFolderName.isEmpty ? trimmedDisplayName : trimmedFolderName
    }

    private var folderNamePreview: String {
        resolvedFolderName.isEmpty ? "[name]" : resolvedFolderName
    }

    private var canCreate: Bool {
        selectedServer != nil && !isCreating && !resolvedFolderName.isEmpty
    }

    private func createProject() async {
        guard let server = selectedServer else { return }
        
        isCreating = true
        defer { isCreating = false }
        
        do {
            let folderName = resolvedFolderName
            if folderName.isEmpty {
                errorMessage = "Enter an agent name or folder name."
                showError = true
                return
            }

            let resolvedDisplayName: String? = {
                if trimmedDisplayName.isEmpty || trimmedDisplayName == folderName {
                    return nil
                }
                return trimmedDisplayName
            }()

            // Determine the effective path
            let effectivePath = customPath ?? server.lastUsedProjectPath ?? detectedPath ?? server.defaultProjectsPath ?? "/root/projects"
            
            // First, create the project folder on the server
            let projectService = ServiceManager.shared.projectService
            try await projectService.createProject(name: folderName, on: server, customPath: effectivePath)
            
            // If a custom path was used, save it to the server
            if let customPath = customPath {
                server.lastUsedProjectPath = customPath
            }
            
            // Create and save the project locally
            let project = RemoteProject(name: folderName,
                                        displayName: resolvedDisplayName,
                                        serverId: server.id,
                                        basePath: effectivePath)
            modelContext.insert(project)
            
            try modelContext.save()
            ShortcutSyncService.shared.sync(using: modelContext)
            
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
            SSHLogger.log("Failed to detect agent path: \(error)", level: .warning)
            detectedPath = "/root/projects" // Explicitly set the fallback
        }
    }
}

struct EditProjectSheet: View {
    let project: RemoteProject

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var displayName: String
    @State private var errorMessage: String?
    @State private var showError = false

    init(project: RemoteProject) {
        self.project = project
        _displayName = State(initialValue: project.displayTitle)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Agent Name") {
                    TextField("Agent Name", text: $displayName)
                        .textInputAutocapitalization(.words)

                    Text("Leave blank to use the folder name.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Agent Folder") {
                    HStack {
                        Text("Folder Name")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(project.name)
                            .fontDesign(.monospaced)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    HStack {
                        Text("Path")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(project.path)
                            .fontDesign(.monospaced)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .navigationTitle("Edit Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveChanges()
                    }
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(errorMessage ?? "An error occurred")
            }
        }
    }

    private func saveChanges() {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == project.name {
            project.displayName = nil
        } else {
            project.displayName = trimmed
        }

        do {
            try modelContext.save()
            ShortcutSyncService.shared.sync(using: modelContext)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
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
                    Text("Are you sure you want to delete '\(project.displayTitle)'?")
                        .font(.body)
                    
                    Toggle("Also delete from server", isOn: $deleteFromServer)
                        .tint(.red)
                    
                    if deleteFromServer {
                        Label {
                            Text("The agent folder and all its contents will be permanently deleted from the server.")
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
                            Text("The agent will only be removed from this app. Files on the server will remain intact.")
                        } icon: {
                            Image(systemName: "iphone")
                                .foregroundColor(.blue)
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Delete Agent")
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
