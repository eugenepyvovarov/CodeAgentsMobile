//
//  EditServerSheet.swift
//  CodeAgentsMobile
//
//  Purpose: Sheet for editing existing server configurations
//  - Allows changing authentication method between password and SSH key
//  - Updates server connection details
//

import SwiftUI
import SwiftData

struct EditServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SSHKey.name) private var sshKeys: [SSHKey]
    @Query private var providers: [ServerProvider]
    
    let server: Server
    
    @State private var serverName: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var authMethod: AuthMethod
    @State private var password = ""
    @State private var selectedKeyId: UUID?
    @State private var isTestingConnection = false
    @State private var testResult: String?
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showingImportKey = false
    @State private var hasPasswordChanged = false
    @State private var isPushEnabled: Bool
    @State private var isConfiguringPush = false
    @State private var pushStatusMessage: String?
    
    enum AuthMethod: String, CaseIterable {
        case password = "Password"
        case key = "SSH Key"
    }
    
    init(server: Server) {
        self.server = server
        self._serverName = State(initialValue: server.name)
        self._host = State(initialValue: server.host)
        self._port = State(initialValue: String(server.port))
        self._username = State(initialValue: server.username)
        self._authMethod = State(initialValue: server.authMethodType == "key" ? .key : .password)
        self._selectedKeyId = State(initialValue: server.sshKeyId)
        self._isPushEnabled = State(initialValue: KeychainManager.shared.hasPushSecret(for: server.id))
    }
    
    private var serverProvider: ServerProvider? {
        providers.first { $0.id == server.providerId }
    }
    
    var isAuthValid: Bool {
        switch authMethod {
        case .password:
            // For existing servers, password is valid if unchanged or if new password is provided
            return !hasPasswordChanged || !password.isEmpty
        case .key:
            return selectedKeyId != nil
        }
    }
    
    var hasChanges: Bool {
        serverName != server.name ||
        host != server.host ||
        port != String(server.port) ||
        username != server.username ||
        (authMethod == .password ? "password" : "key") != server.authMethodType ||
        selectedKeyId != server.sshKeyId ||
        hasPasswordChanged
    }
    
    var body: some View {
        NavigationStack {
            Form {
                // Show provider info if this is a managed server
                if let provider = serverProvider {
                    Section("Managed Server") {
                        HStack {
                            ProviderIcon(
                                providerType: provider.providerType,
                                size: 20,
                                color: provider.providerType == "digitalocean" ? .blue : .orange
                            )
                                .frame(width: 30)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.name)
                                    .font(.headline)
                                Text(provider.providerType == "digitalocean" ? "DigitalOcean" : "Hetzner Cloud")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            // Show cloud-init status if provisioning is incomplete
                            if !server.cloudInitComplete {
                                CloudInitStatusBadge(status: server.cloudInitStatus)
                            } else {
                                // Use same pill style as CloudInitStatusBadge
                                Text("Connected")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.green.opacity(0.15))
                                    .cornerRadius(4)
                            }
                        }
                    }
                }
                
                Section("Server Details") {
                    TextField("Server Name", text: $serverName)
                    TextField("Host", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                
                Section("Authentication") {
                    Picker("Method", selection: $authMethod) {
                        ForEach(AuthMethod.allCases, id: \.self) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    
                    if authMethod == .password {
                        SecureField("Password", text: $password)
                            .onChange(of: password) { _, _ in
                                hasPasswordChanged = true
                            }
                        if !hasPasswordChanged {
                            Text("Leave empty to keep current password")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        if sshKeys.isEmpty {
                            VStack(spacing: 12) {
                                Text("No SSH keys available")
                                    .foregroundColor(.secondary)
                                Button("Import SSH Key") {
                                    showingImportKey = true
                                }
                                .buttonStyle(.bordered)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        } else {
                            Picker("SSH Key", selection: $selectedKeyId) {
                                Text("Select a key").tag(nil as UUID?)
                                ForEach(sshKeys) { key in
                                    HStack {
                                        Text(key.name)
                                        Spacer()
                                        Text(key.keyType)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .tag(key.id as UUID?)
                                }
                            }
                        }
                    }
                }

                Section {
                    HStack {
                        Label("Status", systemImage: isPushEnabled ? "bell.fill" : "bell.slash")
                        Spacer()
                        Text(isPushEnabled ? "Enabled" : "Disabled")
                            .foregroundColor(.secondary)
                    }

                    Button {
                        Task {
                            await configurePushNotifications()
                        }
                    } label: {
                        HStack {
                            if isConfiguringPush {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                                    .scaleEffect(0.8)
                                Text("Configuring...")
                            } else {
                                Label("Enable Push Notifications", systemImage: "bell.badge")
                            }
                        }
                    }
                    .disabled(isPushEnabled || isConfiguringPush)

                    if isPushEnabled {
                        Button(role: .destructive) {
                            disablePushNotifications()
                        } label: {
                            Label("Disable on This Device", systemImage: "bell.slash")
                        }
                    }

                    if let pushStatusMessage {
                        Text(pushStatusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Push Notifications")
                } footer: {
                    Text("Enables push notifications for replies finished on this server’s proxy. You’ll be auto-subscribed when opening an agent chat.")
                        .font(.caption)
                }
                
                Section {
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            if isTestingConnection {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                                    .scaleEffect(0.8)
                                Text("Testing...")
                            } else {
                                Label("Test Connection", systemImage: "network")
                            }
                        }
                    }
                    .disabled(host.isEmpty || username.isEmpty || !isAuthValid || isTestingConnection)
                    
                    if let result = testResult {
                        HStack {
                            Image(systemName: result.contains("Success") ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(result.contains("Success") ? .green : .red)
                            Text(result)
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Edit Server")
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
                    .disabled(!hasChanges || serverName.isEmpty || host.isEmpty || username.isEmpty || !isAuthValid)
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
            .sheet(isPresented: $showingImportKey) {
                ImportSSHKeySheet()
            }
        }
    }
    
    private func testConnection() {
        isTestingConnection = true
        testResult = nil
        
        Task {
            // Create temporary server for testing with new values
            let testServer = Server(
                name: "Test",
                host: host,
                port: Int(port) ?? 22,
                username: username,
                authMethodType: authMethod == .password ? "password" : "key"
            )
            testServer.sshKeyId = selectedKeyId
            
            do {
                // Store credentials temporarily if using password
                if authMethod == .password {
                    if hasPasswordChanged && !password.isEmpty {
                        // Use new password for test
                        try KeychainManager.shared.storePassword(password, for: testServer.id)
                    } else if !hasPasswordChanged {
                        // Use existing password for test
                        if let existingPassword = try? server.retrieveCredentials() {
                            try KeychainManager.shared.storePassword(existingPassword, for: testServer.id)
                        }
                    }
                }
                
                // Test connection
                let sshService = ServiceManager.shared.sshService
                let session = try await sshService.connect(to: testServer)
                
                // Try to execute a simple command to verify connection
                _ = try await session.execute("echo 'Connection test successful'")
                
                // If successful, disconnect and clean up
                session.disconnect()
                if authMethod == .password {
                    try KeychainManager.shared.deletePassword(for: testServer.id)
                }
                
                await MainActor.run {
                    testResult = "Success! Connection established"
                    isTestingConnection = false
                }
            } catch {
                await MainActor.run {
                    testResult = "Failed: \(error.localizedDescription)"
                    isTestingConnection = false
                }
                
                // Clean up credentials even on failure
                if authMethod == .password {
                    try? KeychainManager.shared.deletePassword(for: testServer.id)
                }
            }
        }
    }
    
    private func saveChanges() {
        // Update server properties
        server.name = serverName
        server.host = host
        server.port = Int(port) ?? 22
        server.username = username
        server.authMethodType = authMethod == .password ? "password" : "key"
        server.sshKeyId = authMethod == .key ? selectedKeyId : nil
        
        // Update password if changed
        if authMethod == .password && hasPasswordChanged && !password.isEmpty {
            do {
                try KeychainManager.shared.storePassword(password, for: server.id)
            } catch {
                errorMessage = "Failed to update password: \(error.localizedDescription)"
                showError = true
                return
            }
        }
        
        // If switching from password to key, we keep the password in keychain
        // in case user switches back
        
        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = "Failed to save changes: \(error.localizedDescription)"
            showError = true
        }
    }

    @MainActor
    private func configurePushNotifications() async {
        isConfiguringPush = true
        pushStatusMessage = nil
        defer { isConfiguringPush = false }

        do {
            let granted = try await PushNotificationsManager.shared.requestNotificationAuthorization()
            guard granted else {
                pushStatusMessage = "Notifications permission is disabled in Settings."
                return
            }

            PushNotificationsManager.shared.registerForRemoteNotifications()
            pushStatusMessage = "Configuring server..."

            let secret = try await ProxyInstallerService.shared.enablePushNotifications(on: server)
            try KeychainManager.shared.storePushSecret(secret, for: server.id)

            isPushEnabled = true
            if let activeProject = ProjectContext.shared.activeProject,
               activeProject.serverId == server.id {
                let agentDisplayName = "\(activeProject.displayTitle)@\(server.name)"
                await PushNotificationsManager.shared.recordChatOpened(
                    project: activeProject,
                    server: server,
                    agentDisplayName: agentDisplayName
                )
                pushStatusMessage = "Enabled. Subscribed for \(agentDisplayName)."
            } else {
                pushStatusMessage = "Enabled. Open an agent chat to subscribe."
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func disablePushNotifications() {
        do {
            try KeychainManager.shared.deletePushSecret(for: server.id)
            isPushEnabled = false
            pushStatusMessage = "Disabled on this device."
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

#Preview {
    EditServerSheet(server: Server(
        name: "Test Server",
        host: "example.com",
        port: 22,
        username: "user",
        authMethodType: "password"
    ))
    .modelContainer(for: [Server.self, SSHKey.self], inMemory: true)
}
