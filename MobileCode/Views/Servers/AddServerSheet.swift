//
//  AddServerSheet.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-08.
//
//  Purpose: Reusable sheet for adding new servers
//

import SwiftUI
import SwiftData

struct AddServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SSHKey.name) private var sshKeys: [SSHKey]
    
    @State private var serverName = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMethod: AuthMethod = .password
    @State private var password = ""
    @State private var selectedKeyId: UUID?
    @State private var isTestingConnection = false
    @State private var testResult: String?
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showingImportKey = false
    
    enum AuthMethod: String, CaseIterable {
        case password = "Password"
        case key = "SSH Key"
    }
    
    // Completion handler for when a server is successfully added
    var onServerAdded: ((Server) -> Void)?
    
    var isAuthValid: Bool {
        switch authMethod {
        case .password:
            return !password.isEmpty
        case .key:
            return selectedKeyId != nil
        }
    }
    
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
                        ForEach(AuthMethod.allCases, id: \.self) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    
                    if authMethod == .password {
                        SecureField("Password", text: $password)
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
                    .disabled(serverName.isEmpty || host.isEmpty || username.isEmpty || !isAuthValid)
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
            // Create temporary server for testing
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
                    try KeychainManager.shared.storePassword(password, for: testServer.id)
                }
                
                // Test connection
                // Testing SSH connection
                let sshService = ServiceManager.shared.sshService
                let session = try await sshService.connect(to: testServer)
                
                // Try to execute a simple command to verify connection
                let testCommand = "echo 'Connection test successful'"
                _ = try await session.execute(testCommand)
                // Test command succeeded
                
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
                // Test connection failed
                
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
                if authMethod == .password {
                    try? KeychainManager.shared.deletePassword(for: testServer.id)
                }
            }
        }
    }
    
    private func saveServer() {
        let server = Server(
            name: serverName,
            host: host,
            port: Int(port) ?? 22,
            username: username,
            authMethodType: authMethod == .password ? "password" : "key"
        )
        server.sshKeyId = selectedKeyId
        
        // Save server to database
        modelContext.insert(server)
        
        // Store credentials in keychain if using password
        do {
            if authMethod == .password {
                try KeychainManager.shared.storePassword(password, for: server.id)
            }
            
            // Call completion handler if provided
            onServerAdded?(server)
            
            dismiss()
        } catch {
            errorMessage = "Failed to store credentials: \(error.localizedDescription)"
            showError = true
        }
    }
}

#Preview {
    AddServerSheet()
        .modelContainer(for: [Server.self], inMemory: true)
}