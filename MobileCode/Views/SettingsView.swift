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
    @State private var showingAddServer = false
    @State private var showingAPIKeyEntry = false
    @State private var apiKey = ""
    
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
                
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                    
                    Link("GitHub Repository", destination: URL(string: "https://github.com/eugenepyvovarov/CodeAgentsMobile")!)
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
            loadAPIKey()
        }
    }
    
    private func deleteServer(at offsets: IndexSet) {
        for index in offsets {
            let server = servers[index]
            // Clean up credentials from keychain
            try? KeychainManager.shared.deletePassword(for: server.id)
            // Delete from database
            modelContext.delete(server)
        }
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(server.name)
                .font(.headline)
            
            Text("\(server.username)@\(server.host):\(server.port)")
                .font(.caption)
                .foregroundColor(.secondary)
                .fontDesign(.monospaced)
        }
        .padding(.vertical, 4)
    }
}

struct AddServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    @State private var serverName = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var password = ""
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
                    SecureField("Password", text: $password)
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
                    .disabled(host.isEmpty || username.isEmpty || password.isEmpty || isTestingConnection)
                    
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
                    .disabled(serverName.isEmpty || host.isEmpty || username.isEmpty || password.isEmpty)
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
                authMethodType: "password"
            )
            
            do {
                // Store credentials temporarily
                try KeychainManager.shared.storePassword(password, for: testServer.id)
                
                // Test connection
                print("🔍 Testing SSH connection to \(host):\(port)")
                let sshService = ServiceManager.shared.sshService
                let session = try await sshService.connect(to: testServer)
                
                // Try to execute a simple command to verify connection
                let testCommand = "echo 'Connection test successful'"
                let result = try await session.execute(testCommand)
                print("✅ Test command result: \(result)")
                
                // If successful, disconnect and clean up
                session.disconnect()
                try KeychainManager.shared.deletePassword(for: testServer.id)
                
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
                try? KeychainManager.shared.deletePassword(for: testServer.id)
            }
        }
    }
    
    private func saveServer() {
        let server = Server(
            name: serverName,
            host: host,
            port: Int(port) ?? 22,
            username: username,
            authMethodType: "password"
        )
        
        // Save server to database
        modelContext.insert(server)
        
        // Store credentials in keychain
        do {
            try KeychainManager.shared.storePassword(password, for: server.id)
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