//
//  MCPServersListView.swift
//  CodeAgentsMobile
//
//  Purpose: View for displaying and managing MCP servers for a project
//

import SwiftUI

struct MCPServersListView: View {
    @StateObject private var projectContext = ProjectContext.shared
    @StateObject private var mcpService = MCPService.shared
    
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
        NavigationStack {
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
                        
                        Text("MCP servers extend Claude's capabilities with tools and data sources")
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
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        editingServer = server
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
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddServer = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(project == nil)
                }
            }
            .task {
                await loadServers()
            }
            .sheet(isPresented: $showingAddServer) {
                if let project = project {
                    AddMCPServerSheet(project: project) {
                        // Refresh list after adding
                        Task {
                            await loadServers()
                            // Notify chat view to refresh MCP cache
                            NotificationCenter.default.post(name: .mcpConfigurationChanged, object: nil)
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
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(errorMessage ?? "An error occurred")
            }
        }
    }
    
    private func loadServers() async {
        guard let project = project else { return }
        
        isLoading = true
        
        do {
            let newServers = try await mcpService.fetchServers(for: project)
            // Update servers after fetch completes
            servers = newServers
        } catch MCPServiceError.claudeNotInstalled {
            errorMessage = "Claude Code is not installed on this server"
            showError = true
            servers = []
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        
        isLoading = false
    }
    
    private func deleteServers(at offsets: IndexSet) {
        guard let project = project else { return }
        
        // Remove from local list immediately for better UX
        let serversToDelete = offsets.map { servers[$0] }
        servers.remove(atOffsets: offsets)
        
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