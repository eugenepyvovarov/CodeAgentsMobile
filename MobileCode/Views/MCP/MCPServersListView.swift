//
//  MCPServersListView.swift
//  CodeAgentsMobile
//
//  Purpose: View for displaying and managing MCP servers for a project.
//  Shows a merged view: host-global servers (badge "Host") plus project-scope
//  servers (badge "Project" / "Project (override)" when shadowing a host entry).
//

import SwiftUI

struct MCPServersListView: View {
    /// When false, embed in a parent `NavigationStack` (Abilities tab) and hide Done.
    var embedsInNavigationStack: Bool = true

    @Environment(\.dismiss) private var dismiss
    @StateObject private var projectContext = ProjectContext.shared
    @StateObject private var mcpService = CodingAgentMCPService.shared

    @State private var projectServers: [MCPServer] = []
    @State private var hostServers: [MCPServer] = []
    @State private var isLoading = false
    @State private var showingAddServer = false
    @State private var editingServer: MCPServer?
    @State private var overridingHostServer: MCPServer?
    @State private var hostActionsServer: MCPServer?
    @State private var errorMessage: String?
    @State private var showError = false

    private var project: RemoteProject? {
        projectContext.activeProject
    }

    private var projectServer: Server? {
        guard let project else { return nil }
        return ServerManager.shared.server(withId: project.serverId)
    }

    private var mergedServers: [MergedMCPServer] {
        MergedMCPServer.merge(projectServers: projectServers, hostServers: hostServers)
    }

    private var connectedCount: Int {
        mergedServers.filter { $0.server.status == .connected }.count
    }

    private var statusSummary: String {
        if mergedServers.isEmpty {
            return "No servers configured"
        }
        return "\(connectedCount)/\(mergedServers.count) connected"
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
            if isLoading && mergedServers.isEmpty {
                VStack(spacing: 20) {
                    ProgressView()
                    Text("Loading MCP servers...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if mergedServers.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)

                    Text("No MCP Servers")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("MCP servers extend the agent with tools and data sources. Add one to this project, or enable one of this host's global servers.")
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
                        ForEach(mergedServers) { merged in
                            mergedRow(merged)
                                .accessibilityIdentifier("mcp-server-row-\(merged.server.name.cloudAccessibilityIdentifierFragment)")
                                .swipeActions(allowsFullSwipe: false) {
                                    if merged.source == .project || merged.source == .projectOverride {
                                        Button(role: .destructive) {
                                            deleteProjectServer(merged)
                                        } label: {
                                            if merged.source == .projectOverride {
                                                Label("Revert to Host", systemImage: "arrow.uturn.backward")
                                            } else {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                        }
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
            if let project = project {
                AddMCPServerSheet(project: project) {
                    Task {
                        await loadServers()
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
                    Task {
                        await loadServers()
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
        .sheet(item: $overridingHostServer) { hostServer in
            if let project = project {
                // Prefill from host config and save as project-scope.
                EditMCPServerSheet(project: project, hostServerToOverride: hostServer) {
                    Task {
                        await loadServers()
                        NotificationCenter.default.post(name: .mcpConfigurationChanged, object: nil)
                    }
                }
            }
        }
        .confirmationDialog(
            "MCP Server",
            isPresented: Binding(
                get: { hostActionsServer != nil },
                set: { if !$0 { hostActionsServer = nil } }
            ),
            presenting: hostActionsServer
        ) { hostServer in
            Button {
                Task { await disableHostServerForProject(hostServer) }
            } label: {
                Label("Disable for this project", systemImage: "minus.circle")
            }
            Button {
                overridingHostServer = hostServer
            } label: {
                Label("Override for this project", systemImage: "square.and.pencil")
            }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? "An error occurred")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func mergedRow(_ merged: MergedMCPServer) -> some View {
        MCPServerRow(server: merged.server)
            .contentShape(Rectangle())
            .onTapGesture {
                if merged.server.isManagedServer {
                    errorMessage = "The managed MCP server is required and cannot be edited."
                    showError = true
                    return
                }
                switch merged.source {
                case .project, .projectOverride:
                    editingServer = merged.server
                case .host:
                    hostActionsServer = merged.server
                }
            }
            .overlay(alignment: .trailing) {
                sourceBadge(merged.source)
                    .padding(.trailing, 4)
            }
    }

    @ViewBuilder
    private func sourceBadge(_ source: MergedMCPServer.Source) -> some View {
        Text(source.badgeText)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(source.badgeColor.opacity(0.15))
            .foregroundColor(source.badgeColor)
            .clipShape(Capsule())
    }

    // MARK: - Actions

    private func loadServers() async {
        guard let project else { return }

        isLoading = true

        do {
            let projectServersValue = try await mcpService.fetchServers(for: project, scope: .project)
            let hostServersValue: [MCPServer]
            if let host = projectServer {
                hostServersValue = (try? await mcpService.fetchGlobalServers(for: host)) ?? []
            } else {
                hostServersValue = []
            }

            projectServers = projectServersValue
            hostServers = hostServersValue
            isLoading = false

            // Background: ensure managed entries exist without stalling the list.
            Task {
                await ensureManagedServersInBackground(for: project)
            }
        } catch MCPServiceError.claudeNotInstalled {
            errorMessage = "Unable to load MCP servers. Check OpenCode is running on the server."
            showError = true
            projectServers = []
            hostServers = []
            isLoading = false
        } catch {
            let description = error.localizedDescription
            if description.localizedCaseInsensitiveContains("claude")
                && description.localizedCaseInsensitiveContains("not installed") {
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
        let assessment = ManagedMCPProvisioningAssessment(projectServers: projectServers)
        let hadScheduler = assessment.hasScheduler
        let hadAvatar = assessment.hasAvatar
        let avatarNeedsRepair = assessment.avatarNeedsRepair

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
            do {
                try await mcpService.repairManagedAvatarServer(for: project)
                didChange = true
            } catch {
                SSHLogger.log("MCP list: avatar repair failed: \(error)", level: .debug)
            }
        }

        guard didChange else { return }
        do {
            projectServers = try await mcpService.fetchServers(for: project, scope: .project)
            if let host = projectServer {
                hostServers = (try? await mcpService.fetchGlobalServers(for: host)) ?? hostServers
            }
        } catch {
            SSHLogger.log("MCP list: post-ensure refresh failed: \(error)", level: .debug)
        }
    }

    /// Delete a project-scope entry (also serves as "Revert to host default" for override rows).
    private func deleteProjectServer(_ merged: MergedMCPServer) {
        guard let project else { return }
        let name = merged.server.name
        guard !MCPServer.isManagedServer(name) else {
            errorMessage = "The managed MCP server is required and cannot be removed."
            showError = true
            return
        }
        let shouldRestoreHost = merged.source == .projectOverride
        let host = projectServer

        // Optimistic local removal.
        projectServers.removeAll { $0.name == name }

        Task {
            var hasError = false
            do {
                if shouldRestoreHost {
                    guard let host else {
                        throw MCPServiceError.invalidConfiguration("No host configured for this project")
                    }
                    let hostConfigurations = try await mcpService.globalServerConfigurations(for: host)
                    guard let hostConfiguration = hostConfigurations[name] else {
                        throw MCPServiceError.invalidConfiguration(
                            "Could not find \(name) in \(host.name)'s host configuration"
                        )
                    }
                    try await mcpService.revertProjectServerOverride(
                        named: name,
                        restoring: hostConfiguration,
                        for: project
                    )
                } else {
                    try await mcpService.removeServer(named: name, scope: .project, for: project)
                }
            } catch {
                hasError = true
                errorMessage = shouldRestoreHost
                    ? "Failed to revert \(name) to its host configuration: \(error.localizedDescription)"
                    : "Failed to remove \(name): \(error.localizedDescription)"
                showError = true
            }

            await loadServers()

            if !hasError {
                NotificationCenter.default.post(name: .mcpConfigurationChanged, object: nil)
            }
        }
    }

    /// Write a project-scope stub with `enabled: false` to disable a host-global server for this project.
    private func disableHostServerForProject(_ hostServer: MCPServer) async {
        guard let project else { return }
        guard let host = projectServer else {
            errorMessage = "No host configured for this project."
            showError = true
            return
        }
        guard !MCPServer.isManagedServer(hostServer.name) else {
            errorMessage = "The managed MCP server is required and cannot be disabled."
            showError = true
            return
        }

        do {
            // Pull the raw config from the host so we preserve oauth/timeout/headers in the stub.
            let hostConfigs = try await mcpService.globalServerConfigurations(for: host)
            guard let config = hostConfigs[hostServer.name] else {
                errorMessage = "Could not find \(hostServer.name) on host \(host.name)."
                showError = true
                return
            }
            _ = try await mcpService.disableHostServerForProject(
                named: hostServer.name,
                hostConfiguration: config,
                for: project
            )
            await loadServers()
            NotificationCenter.default.post(name: .mcpConfigurationChanged, object: nil)
        } catch {
            errorMessage = "Failed to disable \(hostServer.name): \(error.localizedDescription)"
            showError = true
            await loadServers()
        }
    }
}

// MARK: - Managed MCP Provisioning

struct ManagedMCPProvisioningAssessment: Equatable {
    let hasScheduler: Bool
    let hasAvatar: Bool
    let avatarNeedsRepair: Bool

    init(projectServers: [MCPServer]) {
        hasScheduler = projectServers.contains(where: \.isManagedSchedulerServer)
        let avatar = projectServers.first(where: \.isManagedAvatarServer)
        hasAvatar = avatar != nil
        avatarNeedsRepair = avatar.map { server in
            server.status == .disconnected || server.status == .unknown
                || (server.statusError?.localizedCaseInsensitiveContains("timeout") == true)
        } ?? false
    }
}

// MARK: - MergedMCPServer

struct MergedMCPServer: Identifiable {
    let server: MCPServer
    let source: Source

    var id: UUID { server.id }

    enum Source: String {
        case host
        case project
        case projectOverride

        var badgeText: String {
            switch self {
            case .host: return "Host"
            case .project: return "Project"
            case .projectOverride: return "Project (override)"
            }
        }

        var badgeColor: Color {
            switch self {
            case .host: return .gray
            case .project: return .blue
            case .projectOverride: return .orange
            }
        }
    }

    /// Pure merge of host-global and project-scope MCP server lists.
    /// Project-scope entries shadow host entries with the same name (`projectOverride`).
    static func merge(projectServers: [MCPServer], hostServers: [MCPServer]) -> [MergedMCPServer] {
        let hostByName = Dictionary(uniqueKeysWithValues: hostServers.map { ($0.name, $0) })
        var mergedByName: [String: MergedMCPServer] = [:]
        for s in hostServers {
            mergedByName[s.name] = MergedMCPServer(server: s, source: .host)
        }
        for s in projectServers {
            if hostByName[s.name] != nil {
                mergedByName[s.name] = MergedMCPServer(server: s, source: .projectOverride)
            } else {
                mergedByName[s.name] = MergedMCPServer(server: s, source: .project)
            }
        }
        return mergedByName.values.sorted { $0.server.name < $1.server.name }
    }
}

#Preview {
    MCPServersListView()
}
