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
    @State private var showingAddServer = false
    @State private var showingAPIKeyEntry = false
    @State private var showingImportSSHKey = false
    @State private var showingTokenEntry = false
    @State private var apiKey = ""
    @State private var authToken = ""
    @State private var selectedAuthMethod = ClaudeCodeService.shared.getCurrentAuthMethod()
    
    var body: some View {
        NavigationStack {
            Form(content: {
                Section("Account") {
                    // Authentication Method Picker
                    Picker("Authentication Method", selection: $selectedAuthMethod) {
                        Text("API Key").tag(ClaudeAuthMethod.apiKey)
                        Text("Authentication Token").tag(ClaudeAuthMethod.token)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .onChange(of: selectedAuthMethod) { _, newMethod in
                        handleAuthMethodChange(newMethod)
                    }
                    
                    // Show appropriate credential entry based on selection
                    if selectedAuthMethod == .apiKey {
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
                    } else {
                        HStack {
                            Label("Auth Token", systemImage: "lock.shield")
                            Spacer()
                            if authToken.isEmpty {
                                Text("Not Set")
                                    .foregroundColor(.secondary)
                            } else {
                                Text("••••••••")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            showingTokenEntry = true
                        }
                    }
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
                        Label("Add Server", systemImage: "plus.circle")
                    }
                }
                
                Section("SSH Keys") {
                    ForEach(sshKeys) { key in
                        SSHKeyRowInline(sshKey: key, usageCount: getUsageCount(for: key))
                            .deleteDisabled(getUsageCount(for: key) > 0)
                    }
                    .onDelete(perform: deleteSSHKey)
                    
                    Button {
                        showingImportSSHKey = true
                    } label: {
                        Label("Add SSH Key", systemImage: "plus.circle")
                    }
                }
                
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
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
                AddServerSheet()
            }
            .sheet(isPresented: $showingAPIKeyEntry) {
                APIKeyEntrySheet(apiKey: $apiKey)
            }
            .sheet(isPresented: $showingTokenEntry) {
                AuthTokenEntrySheet(authToken: $authToken)
            }
            .sheet(isPresented: $showingImportSSHKey) {
                ImportSSHKeySheet()
            }
        }
        .onAppear {
            loadCredentials()
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
    
    private func loadCredentials() {
        // Load API key
        do {
            apiKey = try KeychainManager.shared.retrieveAPIKey()
        } catch {
            apiKey = ""
        }
        
        // Load auth token
        do {
            authToken = try KeychainManager.shared.retrieveAuthToken()
        } catch {
            authToken = ""
        }
        
        // Update auth status
        ClaudeCodeService.shared.authStatus = ClaudeCodeService.shared.hasCredentials() ? .authenticated : .missingCredentials
    }
    
    private func handleAuthMethodChange(_ newMethod: ClaudeAuthMethod) {
        // Update the service
        ClaudeCodeService.shared.setAuthMethod(newMethod)
        
        // Clear the other credential
        ClaudeCodeService.shared.clearOtherCredentials(keepingMethod: newMethod)
        
        // Reload credentials to update UI
        loadCredentials()
    }
    
    private func getUsageCount(for key: SSHKey) -> Int {
        servers.filter { $0.sshKeyId == key.id }.count
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
}

struct SSHKeyRowInline: View {
    let sshKey: SSHKey
    let usageCount: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(sshKey.name)
                    .font(.headline)
                    .foregroundColor(usageCount > 0 ? .secondary : .primary)
                Spacer()
                if usageCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                        Text("\(usageCount) server\(usageCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Text("Type: \(sshKey.keyType)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct ServerRow: View {
    let server: Server
    let projectCount: Int
    @State private var showingEditSheet = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(server.name)
                    .font(.headline)
                    .foregroundColor(projectCount > 0 ? .secondary : .primary)
                Spacer()
                HStack(spacing: 6) {
                    if server.authMethodType == "key" {
                        Image(systemName: "key.horizontal.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if projectCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundColor(.orange)
                            Text("\(projectCount) project\(projectCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            
            Text("\(server.username)@\(server.host):\(server.port)")
                .font(.caption)
                .foregroundColor(.secondary)
                .fontDesign(.monospaced)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            showingEditSheet = true
        }
        .sheet(isPresented: $showingEditSheet) {
            EditServerSheet(server: server)
        }
    }
}

// AddServerSheet has been extracted to a separate file for reusability

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
            // API Key saved to keychain
            dismiss()
        } catch {
            // Failed to save API key
        }
    }
}

struct AuthTokenEntrySheet: View {
    @Binding var authToken: String
    @Environment(\.dismiss) private var dismiss
    @State private var tempToken = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Authentication Token", text: $tempToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Claude Code Authentication Token")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Generate a token using:")
                            .font(.caption)
                        Text("claude setup-token")
                            .font(.caption)
                            .fontDesign(.monospaced)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(4)
                        Text("Your token is stored securely in the device keychain.")
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Token Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveAuthToken()
                    }
                    .disabled(tempToken.isEmpty)
                }
            }
        }
        .onAppear {
            tempToken = authToken
        }
    }
    
    private func saveAuthToken() {
        do {
            // Save to keychain
            try KeychainManager.shared.storeAuthToken(tempToken)
            authToken = tempToken
            // Update auth status
            ClaudeCodeService.shared.authStatus = .authenticated
            dismiss()
        } catch {
            // Failed to save auth token
        }
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: [Server.self], inMemory: true)
}