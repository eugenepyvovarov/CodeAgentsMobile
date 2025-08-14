//
//  ManagedServerListView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-08-12.
//

import SwiftUI
import SwiftData

struct ManagedServerListView: View {
    let provider: ServerProvider
    let dismissAll: (() -> Void)?
    
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    init(provider: ServerProvider, dismissAll: (() -> Void)? = nil) {
        self.provider = provider
        self.dismissAll = dismissAll
    }
    
    @Query private var existingServers: [Server]
    @Query private var sshKeys: [SSHKey]
    
    @State private var cloudServers: [CloudServer] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var selectedServer: CloudServer?
    @State private var showAttachSheet = false
    @State private var showCreateServer = false
    @State private var isServerProvisioning = false
    @State private var shouldRefreshList = true
    
    var body: some View {
        NavigationStack {
            VStack {
                if isLoading {
                    Spacer()
                    ProgressView("Loading servers...")
                    Spacer()
                } else if cloudServers.isEmpty {
                    ContentUnavailableView {
                        Label("No Servers Found", systemImage: "server.rack")
                    } description: {
                        Text("No servers found in this account.")
                    } actions: {
                        Button(action: { showCreateServer = true }) {
                            Label("Create New Server", systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(cloudServers) { server in
                            CloudServerRow(
                                server: server,
                                isAttached: isServerAttached(server),
                                onAttach: { attachServer(server) }
                            )
                        }
                        
                        // Create Server button at the bottom
                        Section {
                            Button(action: { showCreateServer = true }) {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.title3)
                                        .foregroundColor(.blue)
                                    Text("Create New Server")
                                        .font(.body)
                                        .fontWeight(.medium)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
            .navigationTitle(provider.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: loadServers) {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        
                        Button(action: { showCreateServer = true }) {
                            Label("Create Server", systemImage: "plus")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onAppear {
                loadServers()
            }
            .sheet(isPresented: $showAttachSheet) {
                if let server = selectedServer {
                    AttachServerSheet(
                        cloudServer: server,
                        provider: provider,
                        onComplete: { attachedServer in
                            modelContext.insert(attachedServer)
                            try? modelContext.save()
                            showAttachSheet = false
                            selectedServer = nil
                            loadServers()
                        }
                    )
                }
            }
            .sheet(isPresented: $showCreateServer) {
                CreateCloudServerView(
                    provider: provider,
                    dismissAll: dismissAll,
                    isProvisioning: $isServerProvisioning
                ) {
                    // Reload servers after creation  
                    // Only reload if not provisioning
                    if !isServerProvisioning {
                        loadServers()
                    }
                }
                .interactiveDismissDisabled(isServerProvisioning)
                .onDisappear {
                    // Reset provisioning flag when sheet dismisses
                    isServerProvisioning = false
                    shouldRefreshList = true
                }
            }
            .onChange(of: isServerProvisioning) { _, newValue in
                // When provisioning starts, prevent list refresh
                if newValue {
                    print("🔒 Provisioning started - locking sheet")
                    shouldRefreshList = false
                } else {
                    print("🔓 Provisioning ended - unlocking sheet")
                    shouldRefreshList = true
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "An error occurred")
            }
        }
    }
    
    private func isServerAttached(_ cloudServer: CloudServer) -> Bool {
        existingServers.contains { server in
            server.providerServerId == cloudServer.id &&
            server.providerId == provider.id
        }
    }
    
    private func loadServers() {
        isLoading = true
        
        Task {
            do {
                let token = try KeychainManager.shared.retrieveProviderToken(for: provider)
                
                let service: CloudProviderProtocol = provider.providerType == "digitalocean" ?
                    DigitalOceanService(apiToken: token) :
                    HetznerCloudService(apiToken: token)
                
                let servers = try await service.listServers()
                
                await MainActor.run {
                    self.cloudServers = servers
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                    self.isLoading = false
                    self.cloudServers = []
                }
            }
        }
    }
    
    private func attachServer(_ cloudServer: CloudServer) {
        selectedServer = cloudServer
        showAttachSheet = true
    }
}


#Preview {
    ManagedServerListView(provider: ServerProvider(providerType: "digitalocean", name: "DigitalOcean"))
        .modelContainer(for: [Server.self, SSHKey.self, ServerProvider.self], inMemory: true)
}