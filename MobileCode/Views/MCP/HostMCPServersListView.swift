//
//  HostMCPServersListView.swift
//  CodeAgentsMobile
//
//  Purpose: Host-scoped view for managing global MCP servers on a selected SSH host.
//  Replaces GlobalMCPServersListView — no active project/agent required, only a configured Server.
//

import SwiftUI
import SwiftData

struct MCPSelectionLoadRequest: Equatable {
    let requestID: UUID
    let selectionID: UUID

    init(selectionID: UUID, requestID: UUID = UUID()) {
        self.selectionID = selectionID
        self.requestID = requestID
    }

    func canApply(
        activeRequest: MCPSelectionLoadRequest?,
        selectedID: UUID?,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && activeRequest == self && selectedID == selectionID
    }

    static func canPresent(loadedSelectionID: UUID?, selectedID: UUID?) -> Bool {
        guard let selectedID else { return false }
        return loadedSelectionID == selectedID
    }
}

struct HostMCPServersListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Server.name) private var servers: [Server]
    @StateObject private var mcpService = CodingAgentMCPService.shared

    @State private var selectedHost: Server?
    @State private var serversOnHost: [MCPServer] = []
    @State private var isLoading = false
    @State private var showingAddServer = false
    @State private var showingAddHost = false
    @State private var showingImportSheet = false
    @State private var editingServer: MCPServer?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var activeLoadRequest: MCPSelectionLoadRequest?
    @State private var loadedHostID: UUID?

    private var connectedCount: Int {
        serversOnHost.filter { $0.status == .connected }.count
    }

    private var statusSummary: String {
        if serversOnHost.isEmpty {
            return "No servers configured"
        }
        return "\(connectedCount)/\(serversOnHost.count) connected"
    }

    var body: some View {
        Group {
            if servers.isEmpty {
                zeroServersState
            } else if selectedHost == nil {
                ContentUnavailableView(
                    "Select a Host",
                    systemImage: "server.rack",
                    description: Text("Pick a server to manage its global MCP servers.")
                )
            } else if !MCPSelectionLoadRequest.canPresent(
                loadedSelectionID: loadedHostID,
                selectedID: selectedHost?.id
            ) || (isLoading && serversOnHost.isEmpty) {
                VStack(spacing: 20) {
                    ProgressView()
                    Text("Loading MCP servers...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if serversOnHost.isEmpty {
                emptyHostState
            } else {
                hostListBody
            }
        }
        .navigationTitle("MCP Servers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if !servers.isEmpty {
                    Picker("Host", selection: $selectedHost) {
                        Text("Select a host…").tag(nil as Server?)
                        ForEach(servers) { server in
                            Text(server.name).tag(server as Server?)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("mcp-host-picker")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showingAddServer = true
                    } label: {
                        Label("Add Server", systemImage: "plus")
                    }
                    .disabled(selectedHost == nil)

                    if servers.count > 1, selectedHost != nil {
                        Button {
                            showingImportSheet = true
                        } label: {
                            Label("Import from Another Host", systemImage: "square.and.arrow.down.on.square")
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityIdentifier("mcp-host-add-menu")
            }
        }
        .task {
            if selectedHost == nil {
                selectedHost = servers.first
            }
        }
        .task(id: selectedHost?.id) {
            await loadServers()
        }
        .sheet(isPresented: $showingAddServer) {
            if let host = selectedHost {
                AddMCPServerSheet(host: host) {
                    Task {
                        await loadServers()
                        NotificationCenter.default.post(name: .mcpConfigurationChanged, object: nil)
                    }
                }
            }
        }
        .sheet(isPresented: $showingImportSheet) {
            if let targetHost = selectedHost {
                ImportMCPFromHostSheet(targetHost: targetHost) {
                    Task {
                        await loadServers()
                        NotificationCenter.default.post(name: .mcpConfigurationChanged, object: nil)
                    }
                }
            }
        }
        .sheet(item: $editingServer) { server in
            if let host = selectedHost {
                EditMCPServerSheet(host: host, server: server) {
                    Task {
                        await loadServers()
                        NotificationCenter.default.post(name: .mcpConfigurationChanged, object: nil)
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddHost) {
            AddServerSheet { newServer in
                selectedHost = newServer
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? "An error occurred")
        }
    }

    // MARK: - Subviews

    private var zeroServersState: some View {
        ContentUnavailableView {
            Label("No Servers Configured", systemImage: "server.rack")
        } description: {
            Text("Add an SSH server to manage its MCP servers.")
        } actions: {
            Button {
                showingAddHost = true
            } label: {
                Label("Add Server", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .accessibilityIdentifier("mcp-host-zero-servers")
    }

    private var emptyHostState: some View {
        VStack(spacing: 20) {
            Image(systemName: "server.rack")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No MCP Servers")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Global MCP servers on this host are available to all agents that live on it.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button {
                showingAddServer = true
            } label: {
                Label("Add Server", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("mcp-host-empty")
    }

    private var hostListBody: some View {
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
                ForEach(serversOnHost) { server in
                    MCPServerRow(server: server)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard MCPSelectionLoadRequest.canPresent(
                                loadedSelectionID: loadedHostID,
                                selectedID: selectedHost?.id
                            ) else {
                                return
                            }
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
                    Text(selectedHost?.name ?? "Host")
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

    // MARK: - Actions

    private func loadServers() async {
        guard let host = selectedHost else {
            activeLoadRequest = nil
            loadedHostID = nil
            serversOnHost = []
            isLoading = false
            return
        }

        let request = MCPSelectionLoadRequest(selectionID: host.id)
        activeLoadRequest = request
        isLoading = true

        do {
            let newServers = try await mcpService.fetchGlobalServers(for: host)
            guard request.canApply(
                activeRequest: activeLoadRequest,
                selectedID: selectedHost?.id,
                isCancelled: Task.isCancelled
            ) else {
                return
            }
            serversOnHost = newServers
            loadedHostID = host.id
        } catch {
            guard request.canApply(
                activeRequest: activeLoadRequest,
                selectedID: selectedHost?.id,
                isCancelled: Task.isCancelled
            ) else {
                return
            }
            let description = error.localizedDescription
            if description.localizedCaseInsensitiveContains("claude")
                && description.localizedCaseInsensitiveContains("not installed") {
                errorMessage = "Unable to load MCP servers. Check OpenCode is running on the host."
            } else {
                errorMessage = description
            }
            showError = true
            serversOnHost = []
            loadedHostID = host.id
        }

        guard request.canApply(
            activeRequest: activeLoadRequest,
            selectedID: selectedHost?.id,
            isCancelled: Task.isCancelled
        ) else {
            return
        }
        isLoading = false
        activeLoadRequest = nil
    }

    private func deleteServers(at offsets: IndexSet) {
        guard let host = selectedHost else { return }
        guard MCPSelectionLoadRequest.canPresent(
            loadedSelectionID: loadedHostID,
            selectedID: host.id
        ) else {
            return
        }

        let managedIndexes = offsets.filter { serversOnHost[$0].isManagedServer }
        if !managedIndexes.isEmpty {
            errorMessage = "The managed MCP server is required and cannot be removed."
            showError = true
        }

        let deletableIndexes = offsets.filter { !serversOnHost[$0].isManagedServer }
        if deletableIndexes.isEmpty {
            return
        }

        let serversToDelete = deletableIndexes.compactMap { index in
            index < serversOnHost.count ? serversOnHost[index] : nil
        }
        for index in deletableIndexes.sorted(by: >) {
            serversOnHost.remove(at: index)
        }

        Task {
            var hasError = false

            for server in serversToDelete {
                do {
                    try await mcpService.removeServer(named: server.name, from: host)
                } catch {
                    hasError = true
                    errorMessage = "Failed to remove \(server.name): \(error.localizedDescription)"
                    showError = true
                }
            }

            await loadServers()

            if !hasError {
                NotificationCenter.default.post(name: .mcpConfigurationChanged, object: nil)
            }
        }
    }
}

#Preview {
    HostMCPServersListView()
        .modelContainer(for: [Server.self, RemoteProject.self, SSHKey.self, ServerProvider.self])
}
