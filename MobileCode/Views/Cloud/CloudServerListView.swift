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
    @State private var serverToAttach: CloudServer?
    
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
            .sheet(item: $serverToAttach) { server in
                if let provider = selectedProvider {
                    AttachServerSheet(
                        cloudServer: server,
                        provider: provider,
                        onComplete: { attachedServer in
                            // Save the attached server
                            modelContext.insert(attachedServer)
                            try? modelContext.save()
                            serverToAttach = nil
                            
                            // Reload to update UI
                            loadServers()
                        }
                    )
                } else {
                    NavigationStack {
                        ContentUnavailableView(
                            "Provider Unavailable",
                            systemImage: "exclamationmark.triangle",
                            description: Text("Close this sheet and select a provider again.")
                        )
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") {
                                    serverToAttach = nil
                                }
                            }
                        }
                    }
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
        serverToAttach = cloudServer
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
    
    @Query private var sshKeys: [SSHKey]
    
    enum AuthMethod: String, CaseIterable, Identifiable {
        case password = "Password"
        case key = "SSH Key"
        
        var id: String { rawValue }
    }
    
    @State private var authMethod: AuthMethod = .key
    @State private var selectedKeyId: UUID?
    @State private var password: String = ""
    @State private var serverName: String = ""
    @State private var username: String = "root"
    @State private var isTestingConnection = false
    @State private var connectionTestResult: Bool?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showCreateKey = false
    @State private var openCodeAuth = OpenCodeServerAuthConfiguration()
    
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
                    
                    Picker("Authentication", selection: $authMethod) {
                        ForEach(AuthMethod.allCases) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    
                    if authMethod == .password {
                        SecureField("Password", text: $password)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .textContentType(.password)
                    } else {
                        if sshKeys.isEmpty {
                            VStack(spacing: 12) {
                                Text("No SSH keys available")
                                    .foregroundColor(.secondary)
                                Button(action: { showCreateKey = true }) {
                                    Label("Create SSH Key", systemImage: "key")
                                }
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Picker("SSH Key", selection: $selectedKeyId) {
                                Text("Select Key").tag(nil as UUID?)
                                ForEach(sshKeys) { key in
                                    Text(key.name).tag(key.id as UUID?)
                                }
                            }
                            
                            Button(action: { showCreateKey = true }) {
                                Label("Create SSH Key", systemImage: "key")
                            }
                            .font(.footnote)
                            .padding(.top, 4)
                        }
                    }
                }

                Section {
                    Toggle("Server Requires Password", isOn: $openCodeAuth.isEnabled)
                        .accessibilityIdentifier("attach-server-opencode-auth-toggle")

                    if openCodeAuth.isEnabled {
                        TextField("OpenCode Username", text: $openCodeAuth.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("attach-server-opencode-username-field")

                        SecureField("OpenCode Server Password", text: $openCodeAuth.password)
                            .accessibilityIdentifier("attach-server-opencode-password-field")
                    }
                } header: {
                    Text("OpenCode Server")
                } footer: {
                    Text("Use this when the existing server protects OpenCode on 127.0.0.1:4096 with basic auth.")
                        .font(.caption)
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
                    .disabled(!isAuthValid || cloudServer.publicIP == nil || isTestingConnection)
                    
                    Button(action: attachServer) {
                        Text("Attach Server")
                    }
                    .disabled(connectionTestResult != true || !isAuthValid || !openCodeAuth.canSave)
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
        .onAppear(perform: configureDefaults)
        .onChange(of: authMethod) { _, _ in resetTestState() }
        .onChange(of: password) { _, _ in resetTestState() }
        .onChange(of: selectedKeyId) { _, _ in resetTestState() }
        .onChange(of: username) { _, _ in resetTestState() }
    }
    
    private var selectedKey: SSHKey? {
        guard let keyId = selectedKeyId else { return nil }
        return sshKeys.first { $0.id == keyId }
    }
    
    private var isAuthValid: Bool {
        switch authMethod {
        case .password:
            return !password.isEmpty
        case .key:
            return selectedKeyId != nil
        }
    }
    
    private func configureDefaults() {
        serverName = cloudServer.name
        if sshKeys.isEmpty {
            authMethod = .password
        } else if selectedKeyId == nil {
            selectedKeyId = sshKeys.first?.id
        }
    }
    
    private func testConnection() {
        guard let ip = cloudServer.publicIP,
              isAuthValid else { return }
        
        let currentAuthMethod = authMethod
        let currentPassword = password
        let currentUsername = username
        let currentKey = selectedKey
        
        if currentAuthMethod == .key && currentKey == nil {
            return
        }
        
        isTestingConnection = true
        connectionTestResult = nil
        errorMessage = nil
        
        Task {
            do {
                let testServer = Server(
                    name: "Attach-\(cloudServer.name)",
                    host: ip,
                    port: 22,
                    username: currentUsername,
                    authMethodType: currentAuthMethod == .password ? "password" : "key"
                )
                
                defer {
                    if currentAuthMethod == .password {
                        try? KeychainManager.shared.deletePassword(for: testServer.id)
                    }
                }
                
                if currentAuthMethod == .key {
                    testServer.sshKeyId = currentKey?.id
                } else {
                    try KeychainManager.shared.storePassword(currentPassword, for: testServer.id)
                }
                
                let sshService = ServiceManager.shared.sshService
                let session = try await sshService.connect(to: testServer)
                
                let testCommand = "echo 'Connection successful'"
                _ = try await session.execute(testCommand)
                session.disconnect()
                
                await MainActor.run {
                    connectionTestResult = true
                    isTestingConnection = false
                }
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
        guard cloudServer.publicIP != nil,
              connectionTestResult == true,
              isAuthValid else { return }
        
        if authMethod == .key && selectedKey == nil {
            return
        }
        
        let server = CloudServerAttachmentConfiguration.makeAttachedServer(
            cloudServer: cloudServer,
            provider: provider,
            displayName: serverName,
            username: username,
            authMethodType: authMethod == .password ? "password" : "key",
            sshKeyId: selectedKey?.id
        )

        switch authMethod {
        case .password:
            do {
                try KeychainManager.shared.storePassword(password, for: server.id)
            } catch {
                errorMessage = "Failed to store password: \(error.localizedDescription)"
                showError = true
                return
            }
        case .key:
            break
        }

        if let credentials = openCodeAuth.credentials {
            do {
                try KeychainManager.shared.storeOpenCodeServerCredentials(
                    username: credentials.username,
                    password: credentials.password,
                    for: server.id
                )
            } catch {
                errorMessage = "Failed to store OpenCode credentials: \(error.localizedDescription)"
                showError = true
                return
            }
        }
        
        onComplete(server)
        dismiss()
    }
    
    private func resetTestState() {
        connectionTestResult = nil
        errorMessage = nil
    }
}

#Preview {
    CloudServerListView()
        .modelContainer(for: [ServerProvider.self, Server.self, SSHKey.self], inMemory: true)
}
