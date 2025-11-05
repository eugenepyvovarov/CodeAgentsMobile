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
import Crypto

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var servers: [Server]
    @Query(sort: \SSHKey.createdAt, order: .reverse) private var sshKeys: [SSHKey]
    @Query private var projects: [RemoteProject]
    @Query private var providers: [ServerProvider]
    @State private var showingAddServer = false
    @State private var showingCloudProviders = false
    @State private var showingAPIKeyEntry = false
    @State private var showingImportSSHKey = false
    @State private var showingTokenEntry = false
    @State private var selectedProvider: ServerProvider?
    @State private var selectedSSHKey: SSHKey?
    @State private var apiKey = ""
    @State private var authToken = ""
    @State private var selectedAuthMethod = ClaudeCodeService.shared.getCurrentAuthMethod()
    @State private var selectedModelAlias = ClaudeCodeService.shared.getCurrentModelAlias()
    
    private var selectedModelOption: ClaudeModelOption {
        ClaudeCodeService.shared.getModelOption(for: selectedModelAlias) ?? ClaudeCodeService.shared.getCurrentModelOption()
    }
    
    var body: some View {
        NavigationStack {
            Form(content: {
                Section("Anthropic Account") {
                    // Authentication Method Picker
                    Picker("Authentication Method", selection: $selectedAuthMethod) {
                        Text("API Key").tag(ClaudeAuthMethod.apiKey)
                        Text("Authentication Token").tag(ClaudeAuthMethod.token)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .onChange(of: selectedAuthMethod) { _, newMethod in
                        // Only update the auth method, don't clear credentials when just switching tabs
                        ClaudeCodeService.shared.setAuthMethod(newMethod)
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
                    
                    NavigationLink {
                        ClaudeModelSelectionView(selectedModelAlias: $selectedModelAlias)
                    } label: {
                        HStack(alignment: .top) {
                            Label("Claude Model", systemImage: "cpu")
                            Spacer()
                            Text(selectedModelOption.alias)
                                .font(.subheadline)
                                .fontDesign(.monospaced)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section("Cloud Providers") {
                    ForEach(providers) { provider in
                        CloudProviderRow(provider: provider, serverCount: getServerCount(for: provider)) {
                            selectedProvider = provider
                        }
                        .deleteDisabled(getServerCount(for: provider) > 0)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                    .onDelete(perform: deleteProvider)
                    
                    Button {
                        showingCloudProviders = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.accentColor)
                            Text("Add Cloud Provider")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
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
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.accentColor)
                            Text("Add Server")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                
                Section("SSH Keys") {
                    ForEach(sshKeys) { key in
                        SSHKeyRow(sshKey: key, usageCount: getUsageCount(for: key)) {
                            selectedSSHKey = key
                        }
                        .deleteDisabled(getUsageCount(for: key) > 0)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                    .onDelete(perform: deleteSSHKey)
                    
                    Button {
                        showingImportSSHKey = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.accentColor)
                            Text("Add SSH Key")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                }
                
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.1.0")
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
            .onChange(of: selectedModelAlias) { newValue in
                ClaudeCodeService.shared.setCurrentModel(alias: newValue)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingAddServer) {
                CloudServersView(dismissAll: {
                    // Dismiss the CloudServersView sheet when server and project are created
                    showingAddServer = false
                })
            }
            .sheet(isPresented: $showingCloudProviders) {
                CloudProvidersView(onProviderAdded: {
                    // Dismiss the CloudProvidersView sheet when a provider is added
                    showingCloudProviders = false
                })
            }
            .sheet(isPresented: $showingAPIKeyEntry) {
                APIKeyEntrySheet(apiKey: $apiKey)
            }
            .sheet(isPresented: $showingTokenEntry) {
                AuthTokenEntrySheet(authToken: $authToken)
            }
            .sheet(isPresented: $showingImportSSHKey) {
                AddSSHKeySheet()
            }
            .sheet(item: $selectedProvider) { provider in
                EditCloudProviderView(provider: provider)
            }
            .sheet(item: $selectedSSHKey) { key in
                SSHKeyDetailView(sshKey: key)
            }
        }
        .onAppear {
            loadCredentials()
            
            // Check and generate missing public keys for SSH keys
            Task {
                await SSHKeyMaintenanceService.shared.generateMissingPublicKeys(in: modelContext)
            }
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
        
        // Load model preference
        selectedModelAlias = ClaudeCodeService.shared.getCurrentModelAlias()
        
        // Update auth status
        ClaudeCodeService.shared.authStatus = ClaudeCodeService.shared.hasCredentials() ? .authenticated : .missingCredentials
    }
    
    
    private func getUsageCount(for key: SSHKey) -> Int {
        servers.filter { $0.sshKeyId == key.id }.count
    }
    
    private func getServerCount(for provider: ServerProvider) -> Int {
        servers.filter { $0.providerId == provider.id }.count
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
    
    private func deleteProvider(at offsets: IndexSet) {
        for index in offsets {
            let provider = providers[index]
            // Check if provider has any servers
            let hasServers = servers.contains { $0.providerId == provider.id }
            
            if !hasServers {
                // Delete token from keychain
                try? KeychainManager.shared.deleteProviderToken(for: provider)
                // Delete from database
                modelContext.delete(provider)
                
                do {
                    try modelContext.save()
                } catch {
                    print("Failed to delete provider: \(error)")
                }
            }
        }
    }
}

struct CloudProviderRow: View {
    let provider: ServerProvider
    let serverCount: Int
    let onTap: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            // Icon column with fixed width for alignment
            ZStack {
                Circle()
                    .fill(Color(.secondarySystemBackground))
                    .frame(width: 40, height: 40)
                
                ProviderIcon(
                    providerType: provider.providerType,
                    size: 24,
                    color: provider.providerType == "digitalocean" ? .blue : .orange
                )
            }
            
            // Content
            Text(provider.name)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(serverCount > 0 ? .secondary : .primary)
            
            Spacer()
            
            // Server count and lock icon
            if serverCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text("\(serverCount) server\(serverCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                // Provider type label
                Text(provider.providerType == "digitalocean" ? "DigitalOcean" : "Hetzner")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}

struct SSHKeyRow: View {
    let sshKey: SSHKey
    let usageCount: Int
    let onTap: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            // Key name
            Text(sshKey.name)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(usageCount > 0 ? .secondary : .primary)
            
            Spacer()
            
            // Right side - usage indicator
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
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}

struct SSHKeyDetailView: View {
    let sshKey: SSHKey
    @Environment(\.dismiss) private var dismiss
    @State private var showExportOptions = false
    @State private var showCopiedAlert = false
    @State private var copiedKeyType = ""
    @State private var exportError: String?
    @State private var showError = false
    @State private var hasPrivateKey = false
    @State private var hasPassphrase = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Key Information") {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text(sshKey.name)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Type")
                        Spacer()
                        Text(sshKey.keyType)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Public Key")
                        Spacer()
                        Image(systemName: !sshKey.publicKey.isEmpty ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundColor(!sshKey.publicKey.isEmpty ? .green : .red)
                    }
                    
                    HStack {
                        Text("Private Key")
                        Spacer()
                        Image(systemName: hasPrivateKey ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundColor(hasPrivateKey ? .green : .red)
                    }
                    
                    if hasPrivateKey {
                        HStack {
                            Text("Passphrase Protected")
                            Spacer()
                            Image(systemName: hasPassphrase ? "lock.fill" : "lock.open")
                                .foregroundColor(hasPassphrase ? .green : .orange)
                        }
                    }
                }
                
                if !sshKey.publicKey.isEmpty || hasPrivateKey {
                    Section("Export Options") {
                        if !sshKey.publicKey.isEmpty {
                            Button {
                                copyPublicKey()
                            } label: {
                                Label("Copy Public Key", systemImage: "doc.on.doc")
                            }
                            
                            Button {
                                exportPublicKey()
                            } label: {
                                Label("Export Public Key", systemImage: "square.and.arrow.up")
                            }
                        }
                        
                        if hasPrivateKey {
                            Button {
                                copyPrivateKey()
                            } label: {
                                Label("Copy Private Key", systemImage: "doc.on.doc")
                            }
                            
                            Button {
                                exportPrivateKey()
                            } label: {
                                Label("Export Private Key", systemImage: "key")
                            }
                        }
                        
                        if !sshKey.publicKey.isEmpty && hasPrivateKey {
                            Button {
                                exportBothKeys()
                            } label: {
                                Label("Export Both Keys", systemImage: "square.and.arrow.up.on.square")
                            }
                        }
                    }
                }
            }
            .navigationTitle("SSH Key Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                checkPrivateKey()
            }
            .alert("Copied!", isPresented: $showCopiedAlert) {
                Button("OK") {}
            } message: {
                Text("\(copiedKeyType) key copied to clipboard")
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(exportError ?? "Failed to export key")
            }
        }
    }
    
    private func checkPrivateKey() {
        if let _ = try? KeychainManager.shared.retrieveSSHKey(for: sshKey.id) {
            hasPrivateKey = true
            
            // Check if there's a passphrase stored for this key
            if let _ = KeychainManager.shared.retrieveSSHKeyPassphrase(for: sshKey.id) {
                hasPassphrase = true
            }
        }
    }
    
    private func copyPublicKey() {
        UIPasteboard.general.string = sshKey.publicKey
        copiedKeyType = "Public"
        showCopiedAlert = true
    }
    
    private func copyPrivateKey() {
        guard let privateKeyData = try? KeychainManager.shared.retrieveSSHKey(for: sshKey.id) else {
            exportError = "Private key not found"
            showError = true
            return
        }
        
        // Format the key for copying based on key type
        let privateKey: String
        if sshKey.keyType == "Ed25519" {
            // For Ed25519, format as OpenSSH
            privateKey = formatEd25519PrivateKeyForExport(privateKeyData)
        } else if let keyString = String(data: privateKeyData, encoding: .utf8) {
            // For other key types, it might already be in PEM format
            privateKey = keyString
        } else {
            // Try to format as generic PEM
            privateKey = formatPrivateKeyAsPEM(privateKeyData, keyType: sshKey.keyType)
        }
        
        UIPasteboard.general.string = privateKey
        copiedKeyType = "Private"
        showCopiedAlert = true
    }
    
    private func exportPublicKey() {
        let tempDir = FileManager.default.temporaryDirectory
        let publicKeyURL = tempDir.appendingPathComponent("\(sshKey.name).pub")
        
        do {
            try sshKey.publicKey.write(to: publicKeyURL, atomically: true, encoding: .utf8)
            presentShareSheet(with: [publicKeyURL])
        } catch {
            exportError = error.localizedDescription
            showError = true
        }
    }
    
    private func exportPrivateKey() {
        guard let privateKeyData = try? KeychainManager.shared.retrieveSSHKey(for: sshKey.id) else {
            exportError = "Private key not found"
            showError = true
            return
        }
        
        // Format the key for export based on key type
        let privateKey: String
        if sshKey.keyType == "Ed25519" {
            // For Ed25519, format as OpenSSH
            privateKey = formatEd25519PrivateKeyForExport(privateKeyData)
        } else if let keyString = String(data: privateKeyData, encoding: .utf8) {
            // For other key types, it might already be in PEM format
            privateKey = keyString
        } else {
            // Try to format as generic PEM
            privateKey = formatPrivateKeyAsPEM(privateKeyData, keyType: sshKey.keyType)
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let privateKeyURL = tempDir.appendingPathComponent(sshKey.name)
        
        do {
            try privateKey.write(to: privateKeyURL, atomically: true, encoding: .utf8)
            presentShareSheet(with: [privateKeyURL])
        } catch {
            exportError = error.localizedDescription
            showError = true
        }
    }
    
    private func exportBothKeys() {
        guard let privateKeyData = try? KeychainManager.shared.retrieveSSHKey(for: sshKey.id) else {
            exportError = "Private key not found"
            showError = true
            return
        }
        
        // Format the key for export based on key type
        let privateKey: String
        if sshKey.keyType == "Ed25519" {
            // For Ed25519, format as OpenSSH
            privateKey = formatEd25519PrivateKeyForExport(privateKeyData)
        } else if let keyString = String(data: privateKeyData, encoding: .utf8) {
            // For other key types, it might already be in PEM format
            privateKey = keyString
        } else {
            // Try to format as generic PEM
            privateKey = formatPrivateKeyAsPEM(privateKeyData, keyType: sshKey.keyType)
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let privateKeyURL = tempDir.appendingPathComponent(sshKey.name)
        let publicKeyURL = tempDir.appendingPathComponent("\(sshKey.name).pub")
        
        do {
            try privateKey.write(to: privateKeyURL, atomically: true, encoding: .utf8)
            try sshKey.publicKey.write(to: publicKeyURL, atomically: true, encoding: .utf8)
            presentShareSheet(with: [privateKeyURL, publicKeyURL])
        } catch {
            exportError = error.localizedDescription
            showError = true
        }
    }
    
    private func formatEd25519PrivateKeyForExport(_ keyData: Data) -> String {
        // Create OpenSSH format for Ed25519 keys
        var result = "-----BEGIN OPENSSH PRIVATE KEY-----\n"
        
        var data = Data()
        
        // Magic header
        data.append("openssh-key-v1\0".data(using: .utf8)!)
        
        // Add cipher, kdf, kdf options (none for unencrypted)
        data.append(Data([0, 0, 0, 4])) // length
        data.append("none".data(using: .utf8)!)
        data.append(Data([0, 0, 0, 4])) // length
        data.append("none".data(using: .utf8)!)
        data.append(Data([0, 0, 0, 0])) // empty kdf options
        
        // Number of keys
        data.append(Data([0, 0, 0, 1]))
        
        // For Ed25519, the private key is 32 bytes and public key is the next 32 bytes
        let privateKeyBytes = keyData.prefix(32)
        let publicKeyBytes: Data
        
        if keyData.count >= 64 {
            // We have both private and public key stored
            publicKeyBytes = keyData.subdata(in: 32..<64)
        } else {
            // We only have the private key seed, derive the public key
            if let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyBytes) {
                publicKeyBytes = privateKey.publicKey.rawRepresentation
            } else {
                // Fallback - this shouldn't happen with valid keys
                publicKeyBytes = Data(repeating: 0, count: 32)
            }
        }
        
        // Public key section
        var pubKeySection = Data()
        pubKeySection.append(Data([0, 0, 0, 11])) // length of "ssh-ed25519"
        pubKeySection.append("ssh-ed25519".data(using: .utf8)!)
        pubKeySection.append(Data([0, 0, 0, 32])) // length of public key
        pubKeySection.append(publicKeyBytes)
        
        // Add public key section length and data
        var pubKeySectionLength = UInt32(pubKeySection.count).bigEndian
        data.append(Data(bytes: &pubKeySectionLength, count: 4))
        data.append(pubKeySection)
        
        // Private key section
        var privKeySection = Data()
        // Check bytes - must be 8 bytes total (same 4-byte value repeated twice)
        // Using a random value for security, though any value works for unencrypted keys
        let checkValue = UInt32.random(in: 0..<UInt32.max)
        privKeySection.append(withUnsafeBytes(of: checkValue.bigEndian) { Data($0) })
        privKeySection.append(withUnsafeBytes(of: checkValue.bigEndian) { Data($0) })
        privKeySection.append(pubKeySection) // repeat public key section
        privKeySection.append(Data([0, 0, 0, 64])) // length of private key (32 private + 32 public)
        privKeySection.append(privateKeyBytes)
        privKeySection.append(publicKeyBytes)
        privKeySection.append(Data([0, 0, 0, 0])) // comment length
        
        // Pad to block size (8 bytes)
        let padding = (8 - (privKeySection.count % 8)) % 8
        for i in 1...padding {
            privKeySection.append(UInt8(i))
        }
        
        // Add private key section
        var privKeySectionLength = UInt32(privKeySection.count).bigEndian
        data.append(Data(bytes: &privKeySectionLength, count: 4))
        data.append(privKeySection)
        
        // Base64 encode
        let base64String = data.base64EncodedString()
        
        // Add line breaks every 70 characters
        var formattedBase64 = ""
        var index = base64String.startIndex
        while index < base64String.endIndex {
            let endIndex = base64String.index(index, offsetBy: 70, limitedBy: base64String.endIndex) ?? base64String.endIndex
            formattedBase64 += base64String[index..<endIndex]
            formattedBase64 += "\n"
            index = endIndex
        }
        
        result += formattedBase64
        result += "-----END OPENSSH PRIVATE KEY-----\n"
        
        return result
    }
    
    private func formatPrivateKeyAsPEM(_ keyData: Data, keyType: String) -> String {
        // Generic PEM formatting for RSA/ECDSA keys
        // This is a simplified version - real implementation would need proper ASN.1 encoding
        let base64 = keyData.base64EncodedString()
        
        var formatted = "-----BEGIN PRIVATE KEY-----\n"
        var index = base64.startIndex
        while index < base64.endIndex {
            let endIndex = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            formatted += base64[index..<endIndex]
            formatted += "\n"
            index = endIndex
        }
        formatted += "-----END PRIVATE KEY-----\n"
        
        return formatted
    }
    
    private func presentShareSheet(with items: [URL]) {
        let activityController = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {
            var topController = rootViewController
            while let presented = topController.presentedViewController {
                topController = presented
            }
            
            activityController.completionWithItemsHandler = { _, _, _, _ in
                // Clean up temp files
                for url in items {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            
            topController.present(activityController, animated: true)
        }
    }
}

struct ServerRow: View {
    let server: Server
    let projectCount: Int
    @State private var showingEditSheet = false
    @Query private var providers: [ServerProvider]
    
    private var serverProvider: ServerProvider? {
        providers.first { $0.id == server.providerId }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 8) {
                    Text(server.name)
                        .font(.headline)
                        .foregroundColor(projectCount > 0 ? .secondary : .primary)
                    
                    // Show cloud-init status badge if provisioning incomplete
                    if !server.cloudInitComplete && server.providerId != nil {
                        CloudInitStatusBadge(status: server.cloudInitStatus)
                    }
                }
                
                Spacer()
                
                HStack(spacing: 6) {
                    // Show cloud provider badge if applicable
                    if let provider = serverProvider {
                        ProviderIcon(
                            providerType: provider.providerType,
                            size: 14,
                            color: provider.providerType == "digitalocean" ? .blue : .orange
                        )
                    }
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
            // Clear the other credential only when actually saving a new value
            try? KeychainManager.shared.deleteAuthToken()
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
            // Clear the other credential only when actually saving a new value
            try? KeychainManager.shared.deleteAPIKey()
            // Update auth status
            ClaudeCodeService.shared.authStatus = .authenticated
            dismiss()
        } catch {
            // Failed to save auth token
        }
    }
}

struct ClaudeModelSelectionView: View {
    @Binding var selectedModelAlias: String
    @Environment(\.dismiss) private var dismiss
    
    private let modelOptions = ClaudeCodeService.shared.getAvailableModelOptions()
    
    var body: some View {
        List {
            Section {
                ForEach(modelOptions) { option in
                    Button {
                        selectedModelAlias = option.alias
                        dismiss()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(option.alias)
                                    .font(.headline)
                                    .fontDesign(.monospaced)
                                Text(option.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if option.alias == selectedModelAlias {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("Applies to all Claude Code sessions started from this device.")
                    .font(.caption)
            }
        }
        .navigationTitle("Claude Model")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: [Server.self], inMemory: true)
}
