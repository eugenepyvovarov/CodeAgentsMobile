//
//  MCPServersListView.swift
//  CodeAgentsMobile
//
//  Purpose: View for displaying and managing MCP servers for a project
//

import SwiftUI

struct MCPServersListView: View {
    /// When false, embed in a parent `NavigationStack` (Abilities tab) and hide Done.
    var embedsInNavigationStack: Bool = true

    @Environment(\.dismiss) private var dismiss
    @StateObject private var projectContext = ProjectContext.shared
    @StateObject private var mcpService = CodingAgentMCPService.shared
    
    @State private var servers: [MCPServer] = []
    @State private var isLoading = false
    @State private var showingAddServer = false
    @State private var editingServer: MCPServer?
    @State private var errorMessage: String?
    @State private var showError = false
    
    private var project: RemoteProject? {
        projectContext.activeProject
    }
    
    private var connectedCount: Int {
        servers.filter { $0.status == .connected }.count
    }
    
    private var statusSummary: String {
        if servers.isEmpty {
            return "No servers configured"
        }
        return "\(connectedCount)/\(servers.count) connected"
    }
    
    var body: some View {
        Group {
            if embedsInNavigationStack {
                NavigationStack { rootContent }
            } else {
                rootContent
            }
        }
    }

    private var rootContent: some View {
        Group {
            if isLoading && servers.isEmpty {
                // Initial loading state
                VStack(spacing: 20) {
                    ProgressView()
                    Text("Loading MCP servers...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if servers.isEmpty {
                // Empty state
                VStack(spacing: 20) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    
                    Text("No MCP Servers")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("MCP servers extend the agent with tools and data sources")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Button {
                        showingAddServer = true
                    } label: {
                        Label("Add MCP Server", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mcp-add-server-empty-button")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Server list
                List {
                    if isLoading {
                        Section {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Refreshing servers...")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    
                    Section {
                        ForEach(servers) { server in
                            MCPServerRow(server: server)
                                .accessibilityIdentifier("mcp-server-row-\(server.name.cloudAccessibilityIdentifierFragment)")
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if server.isManagedServer {
                                        errorMessage = "The managed MCP server is required and cannot be edited."
                                        showError = true
                                    } else {
                                        editingServer = server
                                    }
                                }
                        }
                        .onDelete(perform: deleteServers)
                    } header: {
                        HStack {
                            Text("Configured Servers")
                            Spacer()
                            Text(statusSummary)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .listStyle(InsetGroupedListStyle())
                .refreshable {
                    await loadServers()
                }
            }
        }
        .navigationTitle("MCP Servers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if embedsInNavigationStack {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("mcp-servers-done-button")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddServer = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(project == nil)
                .accessibilityIdentifier("mcp-add-server-button")
            }
        }
        .task {
            await loadServers()
        }
        .sheet(isPresented: $showingAddServer) {
            // Non-empty sheet content required — empty `if let` sheets can present blank.
            if let project = project {
                AddMCPServerSheet(project: project) {
                    // Refresh list after adding
                    Task {
                        await loadServers()
                        // Notify chat view to refresh MCP cache
                        NotificationCenter.default.post(name: .mcpConfigurationChanged, object: nil)
                    }
                }
            } else {
                NavigationStack {
                    ContentUnavailableView(
                        "No Active Agent",
                        systemImage: "person.crop.circle.badge.xmark",
                        description: Text("Select an agent before adding MCP servers.")
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showingAddServer = false }
                        }
                    }
                }
            }
        }
        .sheet(item: $editingServer) { server in
            if let project = project {
                EditMCPServerSheet(project: project, server: server) {
                    // Refresh list after editing
                    Task {
                        await loadServers()
                        // Notify chat view to refresh MCP cache
                        NotificationCenter.default.post(name: .mcpConfigurationChanged, object: nil)
                    }
                }
            } else {
                NavigationStack {
                    ContentUnavailableView(
                        "No Active Agent",
                        systemImage: "person.crop.circle.badge.xmark",
                        description: Text("Select an agent before editing MCP servers.")
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { editingServer = nil }
                        }
                    }
                }
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? "An error occurred")
        }
    }
    
    private func loadServers() async {
        guard let project = project else { return }
        
        isLoading = true
        
        do {
            // Show configured servers immediately — do not block on provision/connect.
            let newServers = try await mcpService.fetchServers(for: project)
            servers = newServers
            isLoading = false

            // Background: ensure managed entries exist without stalling the list.
            Task {
                await ensureManagedServersInBackground(for: project)
            }
        } catch MCPServiceError.claudeNotInstalled {
            // Claude CLI is not required for OpenCode MCP management.
            errorMessage = "Unable to load MCP servers. Check OpenCode is running on the server."
            showError = true
            servers = []
            isLoading = false
        } catch {
            let description = error.localizedDescription
            if description.localizedCaseInsensitiveContains("claude") &&
                description.localizedCaseInsensitiveContains("not installed") {
                errorMessage = "Unable to load MCP servers. Check OpenCode is running on the server."
            } else {
                errorMessage = description
            }
            showError = true
            isLoading = false
        }
    }

    /// Provision missing managed MCPs / repair failed avatar without blocking first paint.
    private func ensureManagedServersInBackground(for project: RemoteProject) async {
        let hadScheduler = servers.contains(where: \.isManagedSchedulerServer)
        let avatarServer = servers.first(where: \.isManagedAvatarServer)
        let hadAvatar = avatarServer != nil
        let avatarNeedsRepair = avatarServer.map { server in
            server.status == .disconnected || server.status == .unknown
                || (server.statusError?.localizedCaseInsensitiveContains("timeout") == true)
        } ?? false

        // Skip when both managed entries are healthy.
        if hadScheduler, hadAvatar, !avatarNeedsRepair {
            return
        }

        var didChange = false
        if !hadScheduler {
            do {
                try await mcpService.ensureManagedSchedulerServerIfNeeded(for: project)
                didChange = true
            } catch {
                SSHLogger.log("MCP list: scheduler ensure failed: \(error)", level: .debug)
            }
        }
        if !hadAvatar {
            do {
                try await mcpService.ensureManagedAvatarServerIfNeeded(for: project)
                didChange = true
            } catch {
                SSHLogger.log("MCP list: avatar ensure failed: \(error)", level: .debug)
            }
        } else if avatarNeedsRepair {
            // Stale Content-Length script → redeploy NDJSON + reconnect.
            do {
                try await mcpService.repairManagedAvatarServer(for: project)
                didChange = true
            } catch {
                SSHLogger.log("MCP list: avatar repair failed: \(error)", level: .debug)
            }
        }

        guard didChange else { return }
        do {
            servers = try await mcpService.fetchServers(for: project)
        } catch {
            SSHLogger.log("MCP list: post-ensure refresh failed: \(error)", level: .debug)
        }
    }
    
    private func deleteServers(at offsets: IndexSet) {
        guard let project = project else { return }
        
        let managedIndexes = offsets.filter { servers[$0].isManagedServer }
        if !managedIndexes.isEmpty {
            errorMessage = "The managed MCP server is required and cannot be removed."
            showError = true
        }
        
        let deletableIndexes = offsets.filter { !servers[$0].isManagedServer }
        if deletableIndexes.isEmpty {
            return
        }
        
        // Remove non-managed entries immediately for better UX
        let serversToDelete = deletableIndexes.compactMap { index in
            index < servers.count ? servers[index] : nil
        }
        for index in deletableIndexes.sorted(by: >) {
            servers.remove(at: index)
        }
        
        Task {
            var hasError = false
            
            // Delete each server and wait for completion
            for server in serversToDelete {
                do {
                    try await mcpService.removeServer(named: server.name, for: project)
                } catch {
                    hasError = true
                    errorMessage = "Failed to remove \(server.name): \(error.localizedDescription)"
                    showError = true
                }
            }
            
            // Always refresh the list to get the true state
            await loadServers()
            
            // Only notify if all deletions succeeded
            if !hasError {
                // Notify chat view to refresh MCP cache
                NotificationCenter.default.post(name: .mcpConfigurationChanged, object: nil)
            }
        }
    }
}

#Preview {
    MCPServersListView()
}
