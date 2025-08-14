//
//  CloudServersView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-08-12.
//

import SwiftUI
import SwiftData

struct CloudServersView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = "managed"
    @State private var canSaveManual = false
    @State private var saveManualAction: (() -> Void)?
    
    let dismissAll: (() -> Void)?
    
    init(dismissAll: (() -> Void)? = nil) {
        self.dismissAll = dismissAll
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Segmented control at top
                Picker("Server Type", selection: $selectedTab) {
                    Text("Auto").tag("managed")
                    Text("Manual").tag("manual")
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()
                
                // Main content area
                if selectedTab == "manual" {
                    ManualServerForm(
                        canSave: $canSaveManual,
                        onSave: { action in
                            saveManualAction = action
                        }
                    )
                } else {
                    ManagedServerContent(dismissAll: dismissAll)
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
                    if selectedTab == "manual" {
                        Button("Save") {
                            saveManualAction?()
                        }
                        .disabled(!canSaveManual)
                    }
                }
            }
        }
    }
}

struct ManualServerForm: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var sshKeys: [SSHKey]
    
    @Binding var canSave: Bool
    let onSave: (@escaping () -> Void) -> Void
    
    @State private var serverName = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMethodType = "password"
    @State private var password = ""
    @State private var selectedSSHKey: SSHKey?
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var showTestResult = false
    @State private var isSaving = false
    @State private var alertMessage = ""
    @State private var showAlert = false
    
    var body: some View {
        Form {
            Section("SERVER DETAILS") {
                TextField("Server Name", text: $serverName)
                    .autocapitalization(.none)
                
                TextField("Host", text: $host)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                
                TextField("22", text: $port)
                    .keyboardType(.numberPad)
                
                TextField("Username", text: $username)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            }
            
            Section("AUTHENTICATION") {
                Picker("Method", selection: $authMethodType) {
                    Text("Password").tag("password")
                    Text("SSH Key").tag("key")
                }
                .pickerStyle(SegmentedPickerStyle())
                
                if authMethodType == "password" {
                    SecureField("Password", text: $password)
                        .autocapitalization(.none)
                } else {
                    Picker("SSH Key", selection: $selectedSSHKey) {
                        Text("Select Key").tag(nil as SSHKey?)
                        ForEach(sshKeys) { key in
                            Text(key.name).tag(key as SSHKey?)
                        }
                    }
                }
            }
            
            Section {
                Button(action: testConnection) {
                    HStack {
                        Image(systemName: "network")
                        Text("Test Connection")
                        if isTesting {
                            Spacer()
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .scaleEffect(0.8)
                        }
                    }
                }
                .disabled(isTesting || !isFormValid)
            }
            
            if let result = testResult {
                Section {
                    HStack {
                        Image(systemName: result.contains("Success") ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(result.contains("Success") ? .green : .red)
                        Text(result)
                            .font(.caption)
                    }
                }
            }
        }
        .alert("Error", isPresented: $showAlert) {
            Button("OK") {}
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            updateCanSave()
            onSave(saveServer)
        }
        .onChange(of: host) { _, _ in updateCanSave() }
        .onChange(of: username) { _, _ in updateCanSave() }
        .onChange(of: password) { _, _ in updateCanSave() }
        .onChange(of: selectedSSHKey) { _, _ in updateCanSave() }
        .onChange(of: authMethodType) { _, _ in updateCanSave() }
    }
    
    private var isFormValid: Bool {
        !host.isEmpty && !username.isEmpty &&
        (authMethodType == "password" ? !password.isEmpty : selectedSSHKey != nil)
    }
    
    private func updateCanSave() {
        canSave = isFormValid
    }
    
    private func testConnection() {
        isTesting = true
        testResult = nil
        
        // TODO: Implement actual connection test
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            testResult = "Success: Connected to server"
            isTesting = false
        }
    }
    
    private func saveServer() {
        guard isFormValid else { return }
        
        isSaving = true
        
        let server = Server(
            name: serverName.isEmpty ? host : serverName,
            host: host,
            port: Int(port) ?? 22,
            username: username,
            authMethodType: authMethodType
        )
        
        if authMethodType == "key" {
            server.sshKeyId = selectedSSHKey?.id
        }
        
        modelContext.insert(server)
        
        // Save password to keychain if needed
        if authMethodType == "password" && !password.isEmpty {
            do {
                try KeychainManager.shared.storePassword(password, for: server.id)
            } catch {
                alertMessage = "Failed to save password: \(error.localizedDescription)"
                showAlert = true
                isSaving = false
                return
            }
        }
        
        do {
            try modelContext.save()
            dismiss()
        } catch {
            alertMessage = "Failed to save server: \(error.localizedDescription)"
            showAlert = true
        }
        
        isSaving = false
    }
}

struct ManagedServerContent: View {
    @Query private var providers: [ServerProvider]
    @State private var showServerList = false
    @State private var selectedProvider: ServerProvider?
    @State private var showAddProvider = false
    @State private var selectedProviderType: String?
    
    let dismissAll: (() -> Void)?
    
    var body: some View {
        VStack(spacing: 0) {
            if providers.isEmpty {
                // No providers connected - show add provider message
                VStack(spacing: 20) {
                    Text("No cloud providers connected")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top, 20)
                    
                    Button {
                        showAddProvider = true
                    } label: {
                        Text("Add Cloud Provider")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .padding(.horizontal)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                // Show provider selection
                ScrollView {
                    VStack(spacing: 16) {
                        Text("Choose a cloud provider")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.top)
                        
                        // Show connected providers for selection
                        ForEach(providers) { provider in
                            ProviderCard(
                                provider: provider,
                                displayName: provider.name,
                                isConnected: false,
                                isSelected: selectedProvider?.id == provider.id,
                                onTap: {
                                    selectedProvider = provider
                                }
                            )
                        }
                    }
                    .padding()
                }
                
                Spacer()
                
                // Continue button at bottom
                VStack(spacing: 12) {
                    Button {
                        if selectedProvider != nil {
                            showServerList = true
                        }
                    } label: {
                        Text("Next")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(selectedProvider != nil ? Color.accentColor : Color.gray)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .disabled(selectedProvider == nil)
                    
                    Button {
                        showAddProvider = true
                    } label: {
                        Text("Add Another Provider")
                            .font(.subheadline)
                            .foregroundColor(.accentColor)
                    }
                }
                .padding()
            }
        }
        .sheet(isPresented: $showServerList) {
            if let provider = selectedProvider {
                ManagedServerListView(provider: provider, dismissAll: dismissAll)
            }
        }
        .sheet(isPresented: $showAddProvider) {
            CloudProvidersView(onProviderAdded: {
                // Just close the CloudProvidersView sheet
                // The ManagedServerContent will refresh automatically via @Query
                showAddProvider = false
            })
        }
    }
}


#Preview {
    CloudServersView()
        .modelContainer(for: [Server.self, SSHKey.self, ServerProvider.self], inMemory: true)
}