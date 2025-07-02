//
//  SettingsView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var servers: [Server]
    @State private var showingAddServer = false
    @State private var showingAPIKeyEntry = false
    @State private var apiKey = ""
    @State private var selectedTheme = "System"
    @State private var enableBiometrics = true
    @State private var autoSaveEnabled = true
    @State private var syntaxHighlighting = true
    
    let themes = ["System", "Light", "Dark"]
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    HStack {
                        Label("API Key", systemImage: "key")
                        Spacer()
                        if apiKey.isEmpty {
                            Text("Not Set")
                                .foregroundColor(.secondary)
                        } else {
                            Text("••••••••")
                                .foregroundColor(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        showingAPIKeyEntry = true
                    }
                    
                    Toggle("Use Biometric Authentication", isOn: $enableBiometrics)
                }
                
                Section("Servers") {
                    ForEach(servers) { server in
                        ServerRow(server: server)
                    }
                    .onDelete(perform: deleteServer)
                    
                    Button {
                        showingAddServer = true
                    } label: {
                        Label("Add Server", systemImage: "plus.circle")
                    }
                }
                
                Section("Appearance") {
                    Picker("Theme", selection: $selectedTheme) {
                        ForEach(themes, id: \.self) { theme in
                            Text(theme).tag(theme)
                        }
                    }
                    
                    Toggle("Syntax Highlighting", isOn: $syntaxHighlighting)
                }
                
                Section("Editor") {
                    Toggle("Auto-save", isOn: $autoSaveEnabled)
                    
                    HStack {
                        Text("Font Size")
                        Spacer()
                        Stepper("14pt", value: .constant(14), in: 10...20)
                    }
                }
                
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                    
                    Link("GitHub Repository", destination: URL(string: "https://github.com/example/claude-code-mobile")!)
                    
                    Link("Documentation", destination: URL(string: "https://docs.example.com")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingAddServer) {
                AddServerSheet()
            }
            .sheet(isPresented: $showingAPIKeyEntry) {
                APIKeyEntrySheet(apiKey: $apiKey)
            }
        }
        .onAppear {
            createSampleServers()
            loadAPIKey()
        }
    }
    
    private func deleteServer(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(servers[index])
        }
    }
    
    private func createSampleServers() {
        // No longer create sample servers automatically
        // Users should add their own real servers
    }
    
    private func loadAPIKey() {
        do {
            apiKey = try KeychainManager.shared.retrieveAPIKey()
            print("✅ Loaded API key from keychain")
        } catch {
            print("ℹ️ No API key found in keychain: \(error)")
            apiKey = ""
        }
    }
}

struct ServerRow: View {
    let server: Server
    @State private var connectionManager = ConnectionManager.shared
    
    private var isConnected: Bool {
        connectionManager.activeServer?.id == server.id && connectionManager.isConnected
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name)
                    .font(.headline)
                
                Text("\(server.username)@\(server.host):\(server.port)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fontDesign(.monospaced)
            }
            
            Spacer()
            
            Button {
                toggleConnection()
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(isConnected ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    
                    Text(isConnected ? "Connected" : "Connect")
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.systemGray5))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
    
    private func toggleConnection() {
        Task {
            if isConnected {
                connectionManager.disconnect()
            } else {
                await connectionManager.connect(to: server)
            }
        }
    }
}

struct AddServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    @State private var serverName = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMethod = "password"
    @State private var password = ""
    @State private var privateKey = ""
    @State private var isTestingConnection = false
    @State private var testResult: String?
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        NavigationStack {
            Form {
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
                        Text("Password").tag("password")
                        Text("SSH Key").tag("key")
                    }
                    
                    if authMethod == "password" {
                        SecureField("Password", text: $password)
                    } else {
                        Button {
                            // TODO: Implement SSH key import
                        } label: {
                            Label("Import SSH Key", systemImage: "key")
                        }
                        
                        if !privateKey.isEmpty {
                            Text("Key imported")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
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
                    .disabled(host.isEmpty || username.isEmpty || 
                             (authMethod == "password" && password.isEmpty) ||
                             isTestingConnection)
                    
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
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveServer()
                    }
                    .disabled(serverName.isEmpty || host.isEmpty || username.isEmpty ||
                             (authMethod == "password" && password.isEmpty))
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    private func testConnection() {
        isTestingConnection = true
        testResult = nil
        
        Task {
            // Create temporary server for testing
            let testServer = Server(
                name: "Test",
                host: host,
                port: Int(port) ?? 22,
                username: username,
                authMethodType: authMethod
            )
            
            do {
                // Store credentials temporarily
                if authMethod == "password" {
                    try KeychainManager.shared.storePassword(password, for: testServer.id)
                } else {
                    // Handle SSH key
                    if let keyData = privateKey.data(using: .utf8) {
                        try KeychainManager.shared.storeSSHKey(keyData, for: testServer.id)
                    }
                }
                
                // Test connection
                print("🔍 Testing SSH connection to \(host):\(port)")
                let sshService = ServiceManager.shared.sshService
                let session = try await sshService.connect(to: testServer)
                
                // Try to execute a simple command to verify connection
                let testCommand = "echo 'Connection test successful'"
                let result = try await session.execute(testCommand)
                print("✅ Test command result: \(result)")
                
                // If successful, disconnect and clean up
                await sshService.disconnect(from: testServer.id)
                try KeychainManager.shared.deleteCredentials(for: testServer.id)
                
                await MainActor.run {
                    testResult = "Success! Connection established"
                    isTestingConnection = false
                }
            } catch {
                print("❌ Test connection failed: \(error)")
                
                // Provide more specific error messages
                let errorMessage: String
                if let sshError = error as? SSHError {
                    switch sshError {
                    case .connectionFailed(let reason):
                        errorMessage = "Connection failed: \(reason)"
                    case .authenticationFailed:
                        errorMessage = "Authentication failed. Check username/password"
                    case .notConnected:
                        errorMessage = "Could not establish connection"
                    case .commandFailed(let reason):
                        errorMessage = "Command failed: \(reason)"
                    case .fileTransferFailed(let reason):
                        errorMessage = "File transfer failed: \(reason)"
                    }
                } else if error.localizedDescription.contains("Network is unreachable") {
                    errorMessage = "Network unreachable. Check host/port"
                } else if error.localizedDescription.contains("Connection refused") {
                    errorMessage = "Connection refused. SSH service may not be running"
                } else if error.localizedDescription.contains("Operation timed out") {
                    errorMessage = "Connection timed out. Check host/port"
                } else {
                    errorMessage = error.localizedDescription
                }
                
                await MainActor.run {
                    testResult = "Failed: \(errorMessage)"
                    isTestingConnection = false
                }
                
                // Clean up credentials even on failure
                try? KeychainManager.shared.deleteCredentials(for: testServer.id)
            }
        }
    }
    
    private func saveServer() {
        let server = Server(
            name: serverName,
            host: host,
            port: Int(port) ?? 22,
            username: username,
            authMethodType: authMethod
        )
        
        // Save server to database
        modelContext.insert(server)
        
        // Store credentials in keychain
        do {
            if authMethod == "password" {
                try KeychainManager.shared.storePassword(password, for: server.id)
            } else if let keyData = privateKey.data(using: .utf8) {
                try KeychainManager.shared.storeSSHKey(keyData, for: server.id)
            }
            dismiss()
        } catch {
            errorMessage = "Failed to store credentials: \(error.localizedDescription)"
            showError = true
        }
    }
}

struct APIKeyEntrySheet: View {
    @Binding var apiKey: String
    @Environment(\.dismiss) private var dismiss
    @State private var tempKey = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("API Key", text: $tempKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Anthropic API Key")
                } footer: {
                    Text("Your API key is stored securely in the device keychain.")
                        .font(.caption)
                }
            }
            .navigationTitle("API Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveAPIKey()
                    }
                    .disabled(tempKey.isEmpty)
                }
            }
        }
        .onAppear {
            tempKey = apiKey
        }
    }
    
    private func saveAPIKey() {
        do {
            // Save to keychain
            try KeychainManager.shared.storeAPIKey(tempKey)
            apiKey = tempKey
            print("✅ API Key saved to keychain")
            dismiss()
        } catch {
            print("❌ Failed to save API key: \(error)")
        }
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: [Server.self], inMemory: true)
}