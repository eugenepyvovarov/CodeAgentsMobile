//
//  SettingsView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//
//  Purpose: App settings and server management
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var servers: [Server]
    @Query(sort: \SSHKey.createdAt, order: .reverse) private var sshKeys: [SSHKey]
    @Query private var projects: [RemoteProject]
    @Query private var providers: [ServerProvider]
    @State private var showingAddServer = false
    @State private var showingCloudProviders = false
    @State private var showingImportSSHKey = false
    @State private var selectedProvider: ServerProvider?
    @State private var selectedSSHKey: SSHKey?

    private var appVersionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    
    var body: some View {
        NavigationStack {
            Form(content: {
                Section {
                    NavigationLink {
                        AIProviderSettingsView(initialMode: .openCode)
                    } label: {
                        Label("AI Providers", systemImage: "sparkles")
                    }
                    .accessibilityIdentifier("settings-ai-providers-link")
                } header: {
                    Text("OpenCode")
                } footer: {
                    Text("Chat uses OpenCode on your server. Connect providers and models once, then apply them to your servers.")
                }
                
                Section("Cloud Providers") {
                    ForEach(providers) { provider in
                        CloudProviderRow(provider: provider, serverCount: getServerCount(for: provider)) {
                            selectedProvider = provider
                        }
                        .deleteDisabled(getServerCount(for: provider) > 0)
                    }
                    .onDelete(perform: deleteProvider)
                    
                    Button {
                        showingCloudProviders = true
                    } label: {
                        SettingsAddRow(title: "Add Cloud Provider")
                    }
                    .accessibilityIdentifier("settings-add-cloud-provider-button")
                }
                
                Section("Servers") {
                    ForEach(servers) { server in
                        ServerRow(server: server, projectCount: getProjectCount(for: server))
                            .deleteDisabled(getProjectCount(for: server) > 0)
                    }
                    .onDelete(perform: deleteServer)
                    
                    Button {
                        showingAddServer = true
                    } label: {
                        SettingsAddRow(title: "Add Server")
                    }
                    .accessibilityIdentifier("settings-add-server-button")
                }
                
                Section("SSH Keys") {
                    ForEach(sshKeys) { key in
                        SSHKeyRow(sshKey: key, usageCount: getUsageCount(for: key)) {
                            selectedSSHKey = key
                        }
                        .deleteDisabled(getUsageCount(for: key) > 0)
                    }
                    .onDelete(perform: deleteSSHKey)
                    
                    Button {
                        showingImportSSHKey = true
                    } label: {
                        SettingsAddRow(title: "Add SSH Key")
                    }
                    .accessibilityIdentifier("settings-add-ssh-key-button")
                }

                Section("MCP & Skills") {
                    NavigationLink {
                        GlobalMCPServersListView()
                    } label: {
                        Label("MCP Servers", systemImage: "server.rack")
                    }
                    .accessibilityIdentifier("settings-mcp-servers-link")

                    NavigationLink {
                        AgentSkillsListView()
                    } label: {
                        Label("Agent Skills", systemImage: "sparkles")
                    }
                    .accessibilityIdentifier("settings-agent-skills-link")
                }
                
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersionString)
                            .foregroundColor(.secondary)
                    }
                    
                    Link(destination: URL(string: "https://github.com/eugenepyvovarov/CodeAgentsMobile")!) {
                        HStack {
                            Text("GitHub Repository")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Link(destination: URL(string: "https://x.com/selfhosted_ai")!) {
                        HStack {
                            Text("Follow Author on X")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            })
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingAddServer) {
                CloudServersView(dismissAll: {
                    // Dismiss the CloudServersView sheet when server and project are created
                    showingAddServer = false
                })
            }
            .sheet(isPresented: $showingCloudProviders) {
                CloudProvidersView(onProviderAdded: {
                    // Dismiss the CloudProvidersView sheet when a provider is added
                    showingCloudProviders = false
                })
            }
            .sheet(isPresented: $showingImportSSHKey) {
                AddSSHKeySheet()
            }
            .sheet(item: $selectedProvider) { provider in
                EditCloudProviderView(provider: provider)
            }
            .sheet(item: $selectedSSHKey) { key in
                SSHKeyDetailView(sshKey: key)
            }
        }
        .onAppear {
            // Check and generate missing public keys for SSH keys
            Task {
                await SSHKeyMaintenanceService.shared.generateMissingPublicKeys(in: modelContext)
            }
        }
    }
    
    private func deleteServer(at offsets: IndexSet) {
        // Capture ids before delete — model objects may be invalid after context.delete.
        let serverIds = offsets.map { servers[$0].id }
        let serversToDelete = offsets.map { servers[$0] }
        for server in serversToDelete {
            modelContext.delete(server)
        }
        Task {
            for serverId in serverIds {
                // Must run while Keychain still has CODEAGENTS_PUSH_SECRET.
                await PushNotificationsManager.shared.unregisterDevice(serverId: serverId)
                try? KeychainManager.shared.deletePassword(for: serverId)
                try? KeychainManager.shared.deleteOpenCodeServerCredentials(for: serverId)
                try? KeychainManager.shared.deleteDaemonToken(for: serverId)
                try? KeychainManager.shared.deletePushSecret(for: serverId)
            }
        }
    }
    
    private func getUsageCount(for key: SSHKey) -> Int {
        servers.filter { $0.sshKeyId == key.id }.count
    }
    
    private func getServerCount(for provider: ServerProvider) -> Int {
        servers.filter { $0.providerId == provider.id }.count
    }
    
    private func getProjectCount(for server: Server) -> Int {
        projects.filter { $0.serverId == server.id }.count
    }
    
    private func deleteSSHKey(at offsets: IndexSet) {
        for index in offsets {
            let key = sshKeys[index]
            // Only allow deletion if key is not in use
            if getUsageCount(for: key) == 0 {
                // Delete from keychain
                try? KeychainManager.shared.deleteSSHKey(for: key.id)
                // Delete from database
                modelContext.delete(key)
            }
        }
    }
    
    private func deleteProvider(at offsets: IndexSet) {
        for index in offsets {
            let provider = providers[index]
            // Check if provider has any servers
            let hasServers = servers.contains { $0.providerId == provider.id }
            
            if !hasServers {
                // Delete token from keychain
                try? KeychainManager.shared.deleteProviderToken(for: provider)
                // Delete from database
                modelContext.delete(provider)
                
                do {
                    try modelContext.save()
                } catch {
                    print("Failed to delete provider: \(error)")
                }
            }
        }
    }
}

// AddServerSheet has been extracted to a separate file for reusability

#Preview {
    SettingsView()
        .modelContainer(for: [Server.self, SSHKey.self, RemoteProject.self, ServerProvider.self], inMemory: true)
}
