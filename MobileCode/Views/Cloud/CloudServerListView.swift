//
//  CloudServerListView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-08-12.
//

import SwiftUI
import SwiftData

struct CloudServerListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @Query private var providers: [ServerProvider]
    @Query private var existingServers: [Server]
    @Query private var sshKeys: [SSHKey]
    
    @State private var selectedProvider: ServerProvider?
    @State private var cloudServers: [CloudServer] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var selectedServer: CloudServer?
    @State private var showAttachSheet = false
    
    var body: some View {
        NavigationStack {
            VStack {
                if providers.isEmpty {
                    ContentUnavailableView(
                        "No Cloud Providers",
                        systemImage: "cloud",
                        description: Text("Add a cloud provider account first")
                    )
                } else {
                    // Provider selector
                    Picker("Provider", selection: $selectedProvider) {
                        Text("Select Provider").tag(nil as ServerProvider?)
                        ForEach(providers) { provider in
                            Text(provider.name).tag(provider as ServerProvider?)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .padding()
                    
                    if isLoading {
                        Spacer()
                        ProgressView("Loading servers...")
                        Spacer()
                    } else if cloudServers.isEmpty && selectedProvider != nil {
                        ContentUnavailableView(
                            "No Servers Found",
                            systemImage: "server.rack",
                            description: Text("No servers found in this account. Create a new server to get started.")
                        )
                    } else if !cloudServers.isEmpty {
                        List(cloudServers) { server in
                            CloudServerRow(
                                server: server,
                                isAttached: isServerAttached(server),
                                onAttach: { attachServer(server) }
                            )
                        }
                    } else {
                        Spacer()
                        Text("Select a provider to view servers")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
            .navigationTitle("Cloud Servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: loadServers) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(selectedProvider == nil || isLoading)
                }
            }
            .onChange(of: selectedProvider) { _, newValue in
                if newValue != nil {
                    loadServers()
                }
            }
            .sheet(isPresented: $showAttachSheet) {
                if let server = selectedServer, let provider = selectedProvider {
                    AttachServerSheet(
                        cloudServer: server,
                        provider: provider,
                        onComplete: { attachedServer in
                            // Save the attached server
                            modelContext.insert(attachedServer)
                            try? modelContext.save()
                            showAttachSheet = false
                            selectedServer = nil
                            
                            // Reload to update UI
                            loadServers()
                        }
                    )
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
            server.providerId == selectedProvider?.id
        }
    }
    
    private func loadServers() {
        guard let provider = selectedProvider else { return }
        
        isLoading = true
        
        Task {
            do {
                // Get token from keychain
                let token = try KeychainManager.shared.retrieveProviderToken(for: provider)
                
                // Create service
                let service: CloudProviderProtocol = provider.providerType == "digitalocean" ?
                    DigitalOceanService(apiToken: token) :
                    HetznerCloudService(apiToken: token)
                
                // Fetch servers
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

struct CloudServerRow: View {
    let server: CloudServer
    let isAttached: Bool
    let onAttach: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading) {
                    Text(server.name)
                        .font(.headline)
                    
                    HStack {
                        Label(server.status, systemImage: statusIcon)
                            .font(.caption)
                            .foregroundColor(statusColor)
                        
                        if let ip = server.publicIP {
                            Text("• \(ip)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Text("\(server.region) • \(server.sizeInfo)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if isAttached {
                    Label("Attached", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Button("Attach") {
                        onAttach()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private var statusIcon: String {
        switch server.status.lowercased() {
        case "active", "running":
            return "circle.fill"
        case "off", "stopped":
            return "circle"
        default:
            return "exclamationmark.circle"
        }
    }
    
    private var statusColor: Color {
        switch server.status.lowercased() {
        case "active", "running":
            return .green
        case "off", "stopped":
            return .gray
        default:
            return .orange
        }
    }
}

struct AttachServerSheet: View {
    let cloudServer: CloudServer
    let provider: ServerProvider
    let onComplete: (Server) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    @Query private var sshKeys: [SSHKey]
    
    @State private var selectedKeyID: UUID?
    @State private var serverName: String = ""
    @State private var username: String = "root"
    @State private var isTestingConnection = false
    @State private var connectionTestResult: Bool?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showCreateKey = false
    
    private var selectedSSHKey: SSHKey? {
        guard let id = selectedKeyID else { return nil }
        return sshKeys.first(where: { $0.id == id })
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Server Details") {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text(cloudServer.name)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("IP Address")
                        Spacer()
                        Text(cloudServer.publicIP ?? "No public IP")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Provider")
                        Spacer()
                        Text(provider.name)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section("Configuration") {
                    TextField("Display Name", text: $serverName)
                        .autocapitalization(.none)
                    
                    TextField("Username", text: $username)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    
                    NavigationLink {
                        SSHKeySelectionView(
                            selectedKeyID: $selectedKeyID,
                            onAddKey: { showCreateKey = true }
                        )
                    } label: {
                        HStack {
                            Text("SSH Key")
                            Spacer()
                            Text(selectedSSHKey?.name ?? "Select")
                                .foregroundColor(selectedSSHKey == nil ? .secondary : .primary)
                        }
                    }
                }
                
                if let result = connectionTestResult {
                    Section("Connection Test") {
                        HStack {
                            Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(result ? .green : .red)
                            Text(result ? "Connection successful" : "Connection failed")
                        }
                    }
                }
                
                Section {
                    Button(action: testConnection) {
                        if isTestingConnection {
                            HStack {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                                    .scaleEffect(0.8)
                                Text("Testing...")
                            }
                        } else {
                            Text("Test Connection")
                        }
                    }
                    .disabled(selectedSSHKey == nil || cloudServer.publicIP == nil || isTestingConnection)
                    
                    Button(action: attachServer) {
                        Text("Attach Server")
                    }
                    .disabled(connectionTestResult != true)
                }
            }
            .navigationTitle("Attach Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "An error occurred")
            }
            .sheet(isPresented: $showCreateKey) {
                AddSSHKeySheet()
            }
        }
        .onAppear {
            serverName = cloudServer.name
        }
    }
    
    private func testConnection() {
        guard let ip = cloudServer.publicIP,
              let sshKey = selectedSSHKey else { return }
        
        isTestingConnection = true
        connectionTestResult = nil
        
        Task {
            do {
                // Retrieve the private key from keychain
                let privateKeyData = try KeychainManager.shared.retrieveSSHKey(for: sshKey.id)
                guard let privateKeyString = String(data: privateKeyData, encoding: .utf8) else {
                    throw NSError(domain: "SSHTest", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid private key format"])
                }
                
                // Test the connection using SSHService
                let session = try await SSHService.shared.connectToServer(
                    host: ip,
                    port: 22,
                    username: username,
                    authMethod: .key(privateKeyString),
                    purpose: .fileOperations
                )
                
                // Try a simple command to verify connection works
                let testCommand = "echo 'Connection successful'"
                _ = try await session.execute(testCommand)
                
                // If we get here, connection was successful
                await MainActor.run {
                    connectionTestResult = true
                    isTestingConnection = false
                }
                
                // Close the test session
                try await session.disconnect()
                
            } catch {
                await MainActor.run {
                    connectionTestResult = false
                    isTestingConnection = false
                    errorMessage = "Connection failed: \(error.localizedDescription)"
                    showError = true
                }
            }
        }
    }
    
    private func attachServer() {
        guard let ip = cloudServer.publicIP,
              let sshKey = selectedSSHKey else { return }
        
        let server = Server(
            name: serverName.isEmpty ? cloudServer.name : serverName,
            host: ip,
            port: 22,
            username: username,
            authMethodType: "key"
        )
        
        server.sshKeyId = sshKey.id
        server.providerId = provider.id
        server.providerServerId = cloudServer.id
        
        onComplete(server)
        dismiss()
    }
}

#Preview {
    CloudServerListView()
        .modelContainer(for: [ServerProvider.self, Server.self, SSHKey.self], inMemory: true)
}
