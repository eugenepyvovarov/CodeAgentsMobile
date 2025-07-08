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