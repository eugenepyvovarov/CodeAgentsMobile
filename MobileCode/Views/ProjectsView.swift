//
//  ProjectsView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//
//  Purpose: Agents chat list (Messages/Telegram-style conversations).
//

import SwiftUI
import SwiftData

struct ProjectsView: View {
    // MARK: - Environment

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Shared state

    @StateObject private var serverManager = ServerManager.shared
    @StateObject private var projectContext = ProjectContext.shared

    // MARK: - Local UI state

    @State private var showingSettings = false
    @State private var showingAddProject = false
    @State private var projectToDelete: RemoteProject?
    @State private var projectToEdit: RemoteProject?
    @State private var deleteFromServer = false
    @State private var editMode: EditMode = .inactive

    // MARK: - Data

    @Query private var projectsUnsorted: [RemoteProject]

    /// Agents ordered by last chat message (not metadata/hydration bumps).
    private var projects: [RemoteProject] {
        projectsUnsorted.sorted { lhs, rhs in
            if lhs.agentsListSortDate != rhs.agentsListSortDate {
                return lhs.agentsListSortDate > rhs.agentsListSortDate
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private var isEditing: Bool {
        editMode.isEditing
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            chatList
                .navigationTitle("Agents")
                .toolbar { agentsToolbar }
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
                // Soft background sync (independent of push):
                // 1) pull new OpenCode messages + unread badges for listed agents
                // 2) keep CodeAgents daemons current
                .task {
                    backfillLastMessageDatesIfNeeded()
                }
                .task(id: softSyncKey) {
                    await softSyncListedAgents()
                    while !Task.isCancelled {
                        let interval = AgentsListSoftSyncService.shared.messageCheckCooldown
                        let nanos = UInt64(max(15, interval) * 1_000_000_000)
                        try? await Task.sleep(nanoseconds: nanos)
                        guard !Task.isCancelled else { break }
                        guard scenePhase == .active else { continue }
                        await softSyncListedAgents()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await softSyncListedAgents() }
                    }
                }
        }
    }

    // MARK: - List

    @ViewBuilder
    private var chatList: some View {
        if projects.isEmpty {
            emptyState
        } else {
            List {
                ForEach(projects) { project in
                    Group {
                        if isEditing {
                            AgentChatListRow(
                                project: project,
                                isEditing: true,
                                onEdit: { projectToEdit = project },
                                onDelete: { projectToDelete = project }
                            )
                        } else {
                            AgentChatListRow(project: project)
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
                    // Tighten system list cell chrome (main vertical density lever).
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }
            .listStyle(.plain)
            .listRowSpacing(0)
            .environment(\.defaultMinListRowHeight, 1)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Agents Yet", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Create an agent to start chatting with OpenCode on your server.")
        } actions: {
            PrimaryGlassButton {
                showingAddProject = true
            } label: {
                Label("Create Agent", systemImage: "plus.message")
            }
            .accessibilityIdentifier("agents-create-empty-button")
        }
    }

    @ToolbarContentBuilder
    private var agentsToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if !projects.isEmpty {
                EditButton()
            }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if !projects.isEmpty {
                Button {
                    showingAddProject = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("Create Agent")
                .accessibilityIdentifier("agents-compose-button")
            }
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityIdentifier("agents-settings-button")
        }
    }

    /// Stable key for listed agents / servers so soft sync re-runs when the set changes.
    private var softSyncKey: String {
        projects
            .map { "\($0.id.uuidString):\($0.serverId.uuidString)" }
            .sorted()
            .joined(separator: ",")
    }

    /// One-shot: seed `lastMessageAt` from local SwiftData messages for existing agents.
    private func backfillLastMessageDatesIfNeeded() {
        guard !projectsUnsorted.isEmpty else { return }
        var didChange = false
        for project in projectsUnsorted {
            let projectId = project.id
            var descriptor = FetchDescriptor<Message>(
                predicate: #Predicate { message in
                    message.projectId == projectId
                },
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
            descriptor.fetchLimit = 1
            guard let latest = try? modelContext.fetch(descriptor).first else { continue }
            let before = project.lastMessageAt
            project.noteLastMessage(at: latest.timestamp)
            if project.lastMessageAt != before {
                didChange = true
            }
        }
        if didChange {
            try? modelContext.save()
        }
    }

    /// Best-effort daemon upgrade + message hydrate while Agents is visible.
    private func softSyncListedAgents() async {
        guard !projects.isEmpty else { return }

        // Message hydrate first so badges update even if daemon upgrade is slow.
        await AgentsListSoftSyncService.shared.softSyncMessages(
            projects: Array(projects),
            modelContext: modelContext
        )

        var seen = Set<UUID>()
        var targets: [Server] = []
        for project in projects {
            guard seen.insert(project.serverId).inserted else { continue }
            if let server = serverManager.server(withId: project.serverId) {
                targets.append(server)
                continue
            }
            let serverId = project.serverId
            let descriptor = FetchDescriptor<Server>(
                predicate: #Predicate { server in
                    server.id == serverId
                }
            )
            if let server = try? modelContext.fetch(descriptor).first {
                targets.append(server)
            }
        }

        guard !targets.isEmpty else { return }
        await CodeAgentsDaemonUpdateService.shared.softEnsureUpToDate(servers: targets)
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
                        .accessibilityIdentifier("add-agent-display-name-field")

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
                                    
                                    Text("This server is still installing OpenCode. Creating an agent now may fail.")
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
                            .accessibilityIdentifier("add-agent-folder-name-field")

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
                    .accessibilityIdentifier("add-agent-create-button")
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
            ProjectContext.shared.setActiveProject(project)
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
