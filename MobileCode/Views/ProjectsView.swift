//
//  ProjectsView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//

import SwiftUI
import SwiftData

struct ProjectsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allProjects: [Project]
    @State private var viewModel = ProjectsViewModel()
    @State private var showingNewProject = false
    @State private var showingSettings = false
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .recent
    @StateObject private var projectManager = ProjectManager.shared
    @StateObject private var connectionManager = ConnectionManager.shared
    @StateObject private var projectContext = ProjectContext.shared
    
    enum SortOrder {
        case alphabetical
        case recent
    }
    
    // Show only local projects (they get created when discovered projects are activated)
    var allAvailableProjects: [Project] {
        return allProjects
    }
    
    var filteredAndSortedProjects: [Project] {
        let filtered = searchText.isEmpty ? allAvailableProjects : allAvailableProjects.filter { project in
            project.name.localizedCaseInsensitiveContains(searchText)
        }
        
        switch sortOrder {
        case .alphabetical:
            return filtered.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .recent:
            return filtered.sorted { $0.lastAccessed > $1.lastAccessed }
        }
    }
    
    var body: some View {
        NavigationStack {
            List {
                if !filteredAndSortedProjects.isEmpty {
                    ForEach(filteredAndSortedProjects) { project in
                        ProjectRow(project: project)
                    }
                } else {
                        // Empty state - no projects at all
                        VStack(spacing: 16) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 50))
                                .foregroundColor(.secondary)
                            
                            Text("No Projects")
                                .font(.title2)
                                .fontWeight(.semibold)
                            
                            Text("Create your first project to get started")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                            
                            Button {
                                showingNewProject = true
                            } label: {
                                Text("Create New Project")
                                    .font(.footnote)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                            }
                            
                            if connectionManager.isConnected {
                                VStack(spacing: 8) {
                                    Button {
                                        Task {
                                            await discoverAndSyncProjects()
                                        }
                                    } label: {
                                        HStack {
                                            Image(systemName: "arrow.clockwise")
                                            Text("Discover Projects from Server")
                                        }
                                        .font(.footnote)
                                        .foregroundColor(.blue)
                                    }
                                    
                                    Text("Projects are discovered from /root/projects")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.top, 8)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "Search projects")
            .refreshable {
                if connectionManager.isConnected {
                    await discoverAndSyncProjects()
                }
            }
            .navigationTitle("Projects")
            .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Menu {
                            Picker("Sort by", selection: $sortOrder) {
                                Label("Recent", systemImage: "clock")
                                    .tag(SortOrder.recent)
                                Label("Name", systemImage: "textformat")
                                    .tag(SortOrder.alphabetical)
                            }
                        } label: {
                            Image(systemName: sortOrder == .recent ? "clock" : "textformat")
                                .foregroundColor(.blue)
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        HStack(spacing: 16) {
                            Button {
                                showingSettings = true
                            } label: {
                                Image(systemName: "gearshape")
                            }
                            
                            Button {
                                showingNewProject = true
                            } label: {
                                Image(systemName: "plus")
                            }
                        }
                    }
                }
                .sheet(isPresented: $showingNewProject) {
                    NewProjectSheet()
                }
                .sheet(isPresented: $showingSettings) {
                    NavigationStack {
                        SettingsView()
                    }
                }
            }
            .task {
                projectContext.configure(with: modelContext)
            }
        }
        
        private func discoverAndSyncProjects() async {
        await projectManager.discoverProjects()
        
        // Sync discovered projects to local database
        guard let activeServer = connectionManager.activeServer else { return }
        
        let remoteProjects = projectManager.getProjects(for: activeServer.id)
        for remoteProject in remoteProjects {
            // Check if project already exists locally
            let projectPath = remoteProject.path
            let serverId = activeServer.id
            let descriptor = FetchDescriptor<Project>(
                predicate: #Predicate { proj in
                    proj.path == projectPath && proj.serverId == serverId
                }
            )
            
            do {
                let existingProjects = try modelContext.fetch(descriptor)
                if existingProjects.isEmpty {
                    // Create new Project from RemoteProject
                    let project = Project(
                        name: remoteProject.name,
                        path: remoteProject.path,
                        serverId: activeServer.id,
                        language: remoteProject.language
                    )
                    project.gitRemote = remoteProject.repositoryURL
                    project.lastAccessed = remoteProject.lastModified
                    modelContext.insert(project)
                }
            } catch {
                print("❌ Failed to sync project \(remoteProject.name): \(error)")
            }
        }
        
        try? modelContext.save()
    }
}

struct DiscoveredProjectRow: View {
    let project: RemoteProject
    @StateObject private var projectContext = ProjectContext.shared
    @StateObject private var connectionManager = ConnectionManager.shared
    @Environment(\.modelContext) private var modelContext
    @State private var isActivating = false
    
    var body: some View {
        Button {
            Task {
                await activateProject()
            }
        } label: {
            HStack {
                Image(systemName: project.type.iconName)
                    .font(.title2)
                    .foregroundColor(colorForProjectType(project.type.color))
                    .frame(width: 40, height: 40)
                    .background(Color(.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(project.name)
                            .font(.headline)
                        
                        if project.hasGit {
                            Image(systemName: "folder.badge.gearshape")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    
                    HStack {
                        Text(project.language)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(colorForProjectType(project.type.color).opacity(0.2))
                            .foregroundColor(colorForProjectType(project.type.color))
                            .clipShape(Capsule())
                        
                        if let framework = project.framework {
                            Text(framework)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(.systemGray4))
                                .foregroundColor(.secondary)
                                .clipShape(Capsule())
                        }
                    }
                    
                    Text(project.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fontDesign(.monospaced)
                    
                    Text("Last modified \(project.lastModified, style: .relative) ago")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(.vertical, 4)
        }
        .disabled(isActivating)
        .opacity(isActivating ? 0.6 : 1.0)
    }
    
    private func activateProject() async {
        guard let serverId = project.serverId else { return }
        
        isActivating = true
        defer { isActivating = false }
        
        // Find or create the Project model
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
            
            // Activate the project (this will connect to server automatically)
            await projectContext.setActiveProject(projectModel)
            
        } catch {
            print("❌ Failed to activate project: \(error)")
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
}

struct ProjectRow: View {
    let project: Project
    @StateObject private var projectContext = ProjectContext.shared
    @StateObject private var connectionManager = ConnectionManager.shared
    @Environment(\.modelContext) private var modelContext
    @State private var isActivating = false
    
    var body: some View {
        Button {
            Task {
                await activateProject()
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(project.name)
                            .font(.headline)
                        
                        if project.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.caption)
                                .foregroundColor(.yellow)
                        }
                    }
                    
                    Text(project.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fontDesign(.monospaced)
                    
                    HStack(spacing: 4) {
                        if let server = findServer(for: project.serverId) {
                            Image(systemName: "server.rack")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(server.name)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Text("Last accessed \(project.lastAccessed, style: .relative) ago")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
            }
            .padding(.vertical, 4)
        }
        .disabled(isActivating)
        .opacity(isActivating ? 0.6 : 1.0)
    }
    
    private func activateProject() async {
        isActivating = true
        defer { isActivating = false }
        
        // Activate the project (this will connect to server automatically)
        await projectContext.setActiveProject(project)
    }
    
    private func findServer(for serverId: UUID) -> Server? {
        let descriptor = FetchDescriptor<Server>(
            predicate: #Predicate { server in
                server.id == serverId
            }
        )
        return try? modelContext.fetch(descriptor).first
    }
}

struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var projectName = ""
    @State private var selectedServer: Server?
    @State private var isCreating = false
    @StateObject private var connectionManager = ConnectionManager.shared
    @Query(sort: \Server.name) private var servers: [Server]
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    if servers.isEmpty {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text("No servers configured")
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                        
                        NavigationLink("Add Server in Settings") {
                            SettingsView()
                        }
                    } else {
                        Picker("Select Server", selection: $selectedServer) {
                            Text("Choose a server").tag(nil as Server?)
                            ForEach(servers) { server in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(server.name)
                                        Text("\(server.host):\(server.port)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if connectionManager.activeServer?.id == server.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                            .font(.caption)
                                    }
                                }
                                .tag(server as Server?)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }
                }
                
                Section("Project Details") {
                    TextField("Project Name", text: $projectName)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    
                    if let server = selectedServer {
                        Text("Project will be created at:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("/root/projects/\(projectName.isEmpty ? "[name]" : projectName)")
                            .font(.caption)
                            .fontDesign(.monospaced)
                            .foregroundColor(.secondary)
                        Text("on \(server.name)")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                    .disabled(isCreating)
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createProject()
                    }
                    .disabled(projectName.isEmpty || selectedServer == nil || isCreating)
                }
            }
        }
    }
    
    private func createProject() {
        guard let server = selectedServer else { return }
        
        isCreating = true
        
        Task {
            do {
                // Connect to server if not already connected
                if connectionManager.activeServer?.id != server.id {
                    await connectionManager.connect(to: server)
                }
                
                // Create project directory on server
                let sshService = ServiceManager.shared.sshService
                let session = try await sshService.connect(to: server)
                
                let projectPath = "/root/projects/\(projectName)"
                
                // Create project directory
                _ = try await session.execute("mkdir -p '\(projectPath)'")
                
                // Create a new Project model
                let project = Project(
                    name: projectName,
                    path: projectPath,
                    serverId: server.id
                )
                
                modelContext.insert(project)
                try modelContext.save()
                
                // Refresh project list
                await ProjectManager.shared.discoverProjects()
                
                await MainActor.run {
                    isCreating = false
                    dismiss()
                }
                
            } catch {
                print("❌ Failed to create project: \(error)")
                await MainActor.run {
                    isCreating = false
                }
            }
        }
    }
}

struct ProjectDetailView: View {
    let project: Project
    
    var body: some View {
        List {
            Section("Project Info") {
                LabeledContent("Name", value: project.name)
                LabeledContent("Path", value: project.path)
                LabeledContent("Language", value: project.language ?? "Unknown")
            }
            
            Section("Actions") {
                Button {
                    // Open in Claude
                } label: {
                    Label("Open in Claude", systemImage: "message")
                }
                
                Button {
                    // Open Terminal
                } label: {
                    Label("Open Terminal", systemImage: "terminal")
                }
                
                Button {
                    // Browse Files
                } label: {
                    Label("Browse Files", systemImage: "folder")
                }
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    ProjectsView()
        .modelContainer(for: [Project.self, Server.self], inMemory: true)
}