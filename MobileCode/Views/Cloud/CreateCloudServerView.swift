//
//  CreateCloudServerView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-08-12.
//

import SwiftUI
import SwiftData

struct CreateCloudServerView: View {
    let provider: ServerProvider
    let dismissAll: (() -> Void)?
    let onComplete: () -> Void
    @Binding var isProvisioning: Bool
    
    @Environment(\.dismiss) private var dismiss
    
    init(provider: ServerProvider, dismissAll: (() -> Void)? = nil, isProvisioning: Binding<Bool> = .constant(false), onComplete: @escaping () -> Void) {
        self.provider = provider
        self.dismissAll = dismissAll
        self._isProvisioning = isProvisioning
        self.onComplete = onComplete
    }
    @Environment(\.modelContext) private var modelContext
    @Query private var sshKeys: [SSHKey]
    @State private var showProjectCreation = false
    @State private var savedServer: Server?
    
    // Form fields
    @State private var serverName = ""
    @State private var selectedRegion = ""
    @State private var selectedSize = ""
    @State private var selectedImage = "" // Auto-selected, not shown in UI
    @State private var selectedProject = "" // For DigitalOcean
    @State private var selectedSSHKeys: Set<String> = []
    
    // Available options (fetched from API)
    @State private var availableRegions: [(id: String, name: String)] = []
    @State private var availableSizes: [(id: String, name: String, description: String)] = []
    @State private var allDigitalOceanSizes: [(id: String, name: String, description: String, regions: [String])] = []
    @State private var availableImages: [(id: String, name: String)] = []
    @State private var availableProjects: [(id: String, name: String)] = [] // For DigitalOcean
    
    // State management
    @State private var isLoadingOptions = true
    @State private var isCreating = false
    @State private var creationStatus: CreationStatus = .idle
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var createdServer: CloudServer?
    @State private var showGenerateKey = false
    @State private var showSizeSelector = false
    @State private var serverCreationTask: Task<Void, Never>?
    @State private var proxyInstallLogs: [String] = []
    @State private var proxyInstallError: String?
    @State private var proxyInstallTask: Task<Void, Never>?
    
    // Server provisioning status tracking
    @State private var provisioningStatus = ServerProvisioningStatus()
    
    struct ServerProvisioningStatus {
        var providerStatus: String = "new" // "new", "active", "error" from API
        var cloudInitStatus: String = "waiting" // "waiting", "checking", "running", "done", "error"
        var lastChecked: Date = Date()
        var sshAccessible: Bool = false
        var cloudInitCheckAttempts: Int = 0
        var proxyInstallStatus: String = "waiting" // "waiting", "running", "done", "error", "skipped"
    }
    
    enum CreationStatus: Equatable {
        case idle
        case creating
        case polling(serverId: String)
        case checkingCloudInit(serverId: String)
        case installingProxy(serverId: String)
        case success
        case failed(error: String)
    }
    
    var body: some View {
        NavigationStack {
            Group {
                if isLoadingOptions {
                    ProgressView("Loading options...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if creationStatus == .creating || creationStatus.isPolling || creationStatus.isCheckingCloudInit || creationStatus.isInstallingProxy || creationStatus == .success {
                    creationProgressView
                } else {
                    createServerForm
                }
            }
            .navigationTitle("Create Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if creationStatus == .idle || creationStatus.isFailed {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                    
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Create") {
                            createServer()
                        }
                        .disabled(!isFormValid)
                    }
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "An error occurred")
            }
            .onAppear {
                loadOptions()
            }
            .onDisappear {
                // If server creation task is still running when view disappears,
                // cancel it to avoid duplicate monitoring
                if serverCreationTask != nil {
                    serverCreationTask?.cancel()
                    serverCreationTask = nil
                    print("⚠️ Cancelled inline monitoring task on view disappear")
                }
                if proxyInstallTask != nil {
                    proxyInstallTask?.cancel()
                    proxyInstallTask = nil
                    print("Cancelled proxy install task on view disappear")
                }
            }
            .sheet(isPresented: $showGenerateKey) {
                GenerateSSHKeySheet()
            }
            .sheet(isPresented: $showSizeSelector) {
                SizeSelectorSheet(
                    availableSizes: filteredSizes,
                    selectedSize: $selectedSize,
                    providerType: provider.providerType
                )
            }
            .sheet(isPresented: $showProjectCreation) {
                if let server = savedServer {
                    AddProjectSheet(
                        preselectedServer: server,
                        onProjectCreated: {
                            // When project is successfully created, dismiss all views
                            showProjectCreation = false
                            // Call dismissAll if provided to close entire navigation chain
                            if let dismissAll = dismissAll {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    dismissAll()
                                }
                            } else {
                                // Otherwise just dismiss normally
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    onComplete()
                                    dismiss()
                                }
                            }
                        },
                        onSkip: {
                            // When user clicks Skip, dismiss all views
                            showProjectCreation = false
                            // Call dismissAll if provided to close entire navigation chain
                            if let dismissAll = dismissAll {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    dismissAll()
                                }
                            } else {
                                // Otherwise just dismiss normally
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    onComplete()
                                    dismiss()
                                }
                            }
                        }
                    )
                }
            }
        }
    }
    
    private var createServerForm: some View {
        Form {
            Section("Server Configuration") {
                TextField("Server Name", text: $serverName)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                
                Picker("Region", selection: $selectedRegion) {
                    Text("Select Region").tag("")
                    ForEach(availableRegions, id: \.id) { region in
                        Text(region.name).tag(region.id)
                    }
                }
                .onChange(of: selectedRegion) { newRegion in
                    // Clear selected size if it's not available in the new region
                    if provider.providerType == "digitalocean" && !newRegion.isEmpty {
                        let availableSizeIds = filteredSizes.map { $0.id }
                        if !availableSizeIds.contains(selectedSize) {
                            selectedSize = ""
                        }
                    }
                }
                
                // Size selection button
                VStack(alignment: .leading, spacing: 4) {
                    Text("Size")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    
                    Button(action: { showSizeSelector = true }) {
                        HStack {
                            if selectedSize.isEmpty {
                                Text("Select Size")
                                    .foregroundColor(.primary)
                            } else if let selected = filteredSizes.first(where: { $0.id == selectedSize }) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(selected.name)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text(selected.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                
                // OS/Image is automatically selected (latest Ubuntu version)
                
                // DigitalOcean projects
                if provider.providerType == "digitalocean" && !availableProjects.isEmpty {
                    Picker("Agent", selection: $selectedProject) {
                        Text("Default Agent").tag("")
                        ForEach(availableProjects, id: \.id) { project in
                            Text(project.name.isEmpty ? project.id : project.name).tag(project.id)
                        }
                    }
                }
            }
            
            Section("SSH Keys") {
                // Filter to show only keys with public key
                let validKeys = sshKeys.filter { !$0.publicKey.isEmpty }
                
                if validKeys.isEmpty {
                    VStack(spacing: 12) {
                        Text("No SSH keys with public key available")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button(action: { showGenerateKey = true }) {
                            Label("Generate New Key", systemImage: "key.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } else {
                    ForEach(validKeys) { key in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key.name)
                                Text(key.keyType)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if selectedSSHKeys.contains(key.id.uuidString) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.accentColor)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            toggleSSHKey(key.id.uuidString)
                        }
                    }
                    
                    Button(action: { showGenerateKey = true }) {
                        Label("Generate New Key", systemImage: "plus.circle")
                            .font(.footnote)
                    }
                }
            }
        }
    }
    
    private var creationProgressView: some View {
        VStack(spacing: 30) {
            // Animated progress indicator or success checkmark
            ZStack {
                if creationStatus == .success {
                    // Success checkmark
                    Circle()
                        .fill(Color.green.opacity(0.1))
                        .frame(width: 80, height: 80)
                    
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.green)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    // Progress indicator
                    Circle()
                        .stroke(Color.blue.opacity(0.2), lineWidth: 4)
                        .frame(width: 80, height: 80)
                    
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                        .scaleEffect(2)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: creationStatus)
            
            VStack(spacing: 8) {
                Text(creationStatus == .success ? "Server ready!" : creationStatus.isInstallingProxy ? "Installing Claude Proxy..." : "Creating your server")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .animation(.easeInOut(duration: 0.3), value: creationStatus)
                
                if creationStatus == .success {
                    Text("Your server is now active and ready to use")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                } else if creationStatus.isInstallingProxy {
                    Text("Setting up the Claude proxy daemon on your server")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Text("This typically takes 1-2 minutes")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                } else if case .checkingCloudInit = creationStatus {
                    Text("Installing packages and configuring Claude Code...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Text("This typically takes 1-3 minutes")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                } else if case .polling = creationStatus {
                    Text("Configuring network and services...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Initializing server instance...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            
            if let server = createdServer {
                VStack(spacing: 16) {
                    // Server name with icon
                    HStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .font(.title2)
                            .foregroundColor(.blue)
                            .frame(width: 40, height: 40)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(Circle())
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(server.name)
                                .font(.headline)
                            
                            if let ip = server.publicIP {
                                Text(ip)
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Assigning IP address...")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Spacer()
                        
                        // Status indicator - simple, no animations
                        VStack(spacing: 4) {
                            Circle()
                                .fill(server.status == "active" ? Color.green : Color.orange)
                                .frame(width: 10, height: 10)
                            
                            Text(server.status)
                                .font(.caption2)
                                .foregroundColor(server.status == "active" ? .green : .orange)
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                    
                    // Dual status progress
                    VStack(alignment: .leading, spacing: 16) {
                        // Provider Status
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "cloud")
                                    .foregroundColor(.blue)
                                Text("Server Status (\(provider.name))")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Spacer()
                                if provisioningStatus.providerStatus == "active" || provisioningStatus.providerStatus == "running" {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                } else {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                }
                            }
                            
                            HStack(spacing: 8) {
                                ProgressStep(title: "Creating", isComplete: provisioningStatus.providerStatus != "new")
                                Image(systemName: "arrow.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                ProgressStep(title: "Active", isComplete: provisioningStatus.providerStatus == "active" || provisioningStatus.providerStatus == "running")
                            }
                            .padding(.leading, 28)
                        }
                        
                        Divider()
                        
                        // Cloud-init Status
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "terminal")
                                    .foregroundColor(.blue)
                                Text("Configuration Status (cloud-init)")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Spacer()
                                if provisioningStatus.cloudInitStatus == "done" {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                } else if provisioningStatus.cloudInitStatus == "error" {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundColor(.red)
                                } else if provisioningStatus.cloudInitStatus != "waiting" {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                }
                            }
                            
                            HStack(spacing: 8) {
                                ProgressStep(
                                    title: provisioningStatus.cloudInitStatus == "waiting" ? "Waiting" : 
                                           provisioningStatus.cloudInitStatus == "checking" ? "Connecting" :
                                           provisioningStatus.cloudInitStatus == "running" ? "Installing" :
                                           provisioningStatus.cloudInitStatus == "done" ? "Complete" : "Error",
                                    isComplete: provisioningStatus.cloudInitStatus == "done"
                                )
                            }
                            .padding(.leading, 28)
                        }

                        Divider()

                        // Claude Proxy Install
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "bolt.circle")
                                    .foregroundColor(.blue)
                                Text("Claude Proxy Install")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Spacer()
                                if provisioningStatus.proxyInstallStatus == "done" {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                } else if provisioningStatus.proxyInstallStatus == "error" {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundColor(.red)
                                } else if provisioningStatus.proxyInstallStatus == "skipped" {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.orange)
                                } else if provisioningStatus.proxyInstallStatus != "waiting" {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                }
                            }
                            
                            HStack(spacing: 8) {
                                ProgressStep(
                                    title: provisioningStatus.proxyInstallStatus == "waiting" ? "Waiting" :
                                           provisioningStatus.proxyInstallStatus == "running" ? "Installing" :
                                           provisioningStatus.proxyInstallStatus == "done" ? "Complete" :
                                           provisioningStatus.proxyInstallStatus == "skipped" ? "Skipped" : "Error",
                                    isComplete: provisioningStatus.proxyInstallStatus == "done"
                                )
                            }
                            .padding(.leading, 28)
                        }
                    }
                    .padding()
                    .background(Color(UIColor.tertiarySystemBackground))
                    .cornerRadius(12)
                }
                .transition(.opacity.combined(with: .scale))
                .animation(.easeInOut, value: createdServer)
            }

            if !proxyInstallLogs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Installer Output")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    ScrollView {
                        Text(proxyInstallLogs.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    .padding(8)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(8)
                }
            }

            if let proxyInstallError = proxyInstallError {
                Text(proxyInstallError)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
            
            // Action buttons based on status
            if provisioningStatus.proxyInstallStatus == "error" {
                VStack(spacing: 12) {
                    Button("Retry Install") {
                        retryProxyInstall()
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Button("Skip for Now") {
                        skipProxyInstall()
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: provisioningStatus.proxyInstallStatus)
            } else if creationStatus == .success {
                // Server is fully ready - show Add Agent button
                VStack(spacing: 12) {
                    Button(action: addProject) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Agent")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(12)
                    }
                    
                    Button("Skip for Now") {
                        // Save the server to database if not already saved
                        if let server = savedServer {
                            modelContext.insert(server)
                            do {
                                try modelContext.save()
                                print("💾 Server saved to database on 'Skip for Now'")
                            } catch {
                                print("Failed to save server: \(error)")
                            }
                        }
                        onComplete()
                        dismiss()
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: creationStatus)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemBackground))
    }
    
    private var successView: some View {
        VStack(spacing: 30) {
            // Success icon with animation
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.green)
                    .transition(.scale.combined(with: .opacity))
            }
            
            VStack(spacing: 8) {
                Text("Server Ready!")
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("Your server is now active and ready to use")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            if let server = createdServer {
                VStack(spacing: 12) {
                    // Server card
                    HStack(spacing: 16) {
                        ProviderLogo(providerType: provider.providerType, size: 50)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text(server.name)
                                .font(.headline)
                            
                            if let ip = server.publicIP {
                                HStack(spacing: 4) {
                                    Image(systemName: "network")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(ip)
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                                
                                Text("Active")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                        }
                        
                        Spacer()
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                }
            }
            
            Spacer()
            
            // Action buttons
            VStack(spacing: 12) {
                Button(action: addProject) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Agent")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(12)
                }
                
                Button("Skip for Now") {
                    // Create and save the server record only if not already saved
                    if savedServer == nil, let cloudServer = createdServer {
                        _ = createAndSaveServerRecord(from: cloudServer)
                    }
                    onComplete()
                    dismiss()
                }
                .font(.footnote)
                .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemBackground))
    }
    
    private var filteredSizes: [(id: String, name: String, description: String)] {
        // For DigitalOcean, filter sizes by selected region
        if provider.providerType == "digitalocean" && !selectedRegion.isEmpty && !allDigitalOceanSizes.isEmpty {
            return allDigitalOceanSizes.filter { size in
                size.regions.contains(selectedRegion)
            }.map { size in
                (id: size.id, name: size.name, description: size.description)
            }
        }
        // For other providers or when no region selected, return all sizes
        return availableSizes
    }
    
    private var isFormValid: Bool {
        !serverName.isEmpty &&
        !selectedRegion.isEmpty &&
        !selectedSize.isEmpty &&
        true // Image is auto-selected
    }
    
    private func toggleSSHKey(_ keyId: String) {
        if selectedSSHKeys.contains(keyId) {
            selectedSSHKeys.remove(keyId)
        } else {
            selectedSSHKeys.insert(keyId)
        }
    }
    
    private func addProject() {
        // Create and save the server record first (only if not already saved)
        if savedServer == nil, let cloudServer = createdServer {
            savedServer = createAndSaveServerRecord(from: cloudServer)
        }
        
        // Save the server to database when user chooses to add a project
        if let server = savedServer {
            modelContext.insert(server)
            do {
                try modelContext.save()
                print("💾 Server saved to database on 'Add Agent'")
            } catch {
                print("Failed to save server: \(error)")
            }
        }
        
        // Navigate to project creation
        showProjectCreation = true
    }
    
    private func loadOptions() {
        Task {
            await loadOptionsFromAPI()
        }
    }
    
    @MainActor
    private func loadOptionsFromAPI() async {
        isLoadingOptions = true
        
        // Get the appropriate service
        let service: CloudProviderProtocol
        if provider.providerType == "digitalocean" {
            guard let token = try? KeychainManager.shared.retrieveProviderToken(for: provider) else {
                print("No token found for provider")
                isLoadingOptions = false
                errorMessage = "No API token found. Please configure your provider settings."
                showError = true
                return
            }
            service = DigitalOceanService(apiToken: token)
        } else {
            guard let token = try? KeychainManager.shared.retrieveProviderToken(for: provider) else {
                print("No token found for provider")
                isLoadingOptions = false
                errorMessage = "No API token found. Please configure your provider settings."
                showError = true
                return
            }
            service = HetznerCloudService(apiToken: token)
        }
        
        do {
            // Load regions and sort alphabetically by name
            let regions = try await service.listRegions()
            availableRegions = regions.sorted { $0.name < $1.name }
            
            // Load sizes
            if provider.providerType == "digitalocean",
               let doService = service as? DigitalOceanService {
                // For DigitalOcean, get sizes with region information
                let sizesWithRegions = try await doService.listSizesWithRegions()
                allDigitalOceanSizes = sizesWithRegions
                // Set availableSizes for initial display (all sizes)
                availableSizes = sizesWithRegions.map { (id: $0.id, name: $0.name, description: $0.description) }
            } else {
                // For other providers, use regular sizes
                let sizes = try await service.listSizes()
                availableSizes = sizes
            }
            
            // Load images
            let images = try await service.listImages()
            availableImages = images
            
            // Log DigitalOcean images for debugging
            if provider.providerType == "digitalocean" {
                print("📸 DigitalOcean Images Available (\(images.count) total):")
                for (index, img) in images.prefix(20).enumerated() {
                    print("  \(index + 1). ID: '\(img.id)' | Name: '\(img.name)'")
                }
                if images.count > 20 {
                    print("  ... and \(images.count - 20) more images")
                }
            }
            
            // Automatically select the latest Ubuntu version
            selectedImage = selectLatestUbuntuImage()
            
            // Debug: Print selected image
            print("✅ Selected image: '\(selectedImage)'")
            if selectedImage.isEmpty {
                print("⚠️ Warning: No Ubuntu image found")
            }
            
            isLoadingOptions = false
            
            // Load DigitalOcean projects if applicable
            if provider.providerType == "digitalocean" {
                loadProjects()
            }
        } catch {
            print("Failed to load options from API: \(error)")
            isLoadingOptions = false
            
            // Set appropriate error message based on error type
            if let cloudError = error as? CloudProviderError {
                switch cloudError {
                case .invalidToken:
                    errorMessage = "Invalid API token. Please check your provider settings."
                case .insufficientPermissions:
                    errorMessage = "Insufficient permissions. Please check your API token permissions."
                case .rateLimitExceeded:
                    errorMessage = "Rate limit exceeded. Please try again later."
                case .apiError(_, let message):
                    errorMessage = "API Error: \(message)"
                default:
                    errorMessage = "Failed to load server options: \(error.localizedDescription)"
                }
            } else {
                errorMessage = "Failed to load server options: \(error.localizedDescription)"
            }
        }
    }
    
    private func loadProjects() {
        // TODO: Fetch projects from DigitalOcean API
        // For now, we'll just use the default project
    }
    
    private func createServer() {
        creationStatus = .creating
        isProvisioning = true  // Start provisioning
        print("🚀 Starting server provisioning - isProvisioning set to true")
        provisioningStatus = ServerProvisioningStatus()
        proxyInstallLogs = []
        proxyInstallError = nil
        proxyInstallTask?.cancel()
        proxyInstallTask = nil
        
        // Cancel any existing task
        serverCreationTask?.cancel()
        
        serverCreationTask = Task {
            do {
                // Get API token
                let token = try KeychainManager.shared.retrieveProviderToken(for: provider)
                
                // Create service
                let service: CloudProviderProtocol = provider.providerType == "digitalocean" ?
                    DigitalOceanService(apiToken: token) :
                    HetznerCloudService(apiToken: token)
                
                // For DigitalOcean, we need to upload SSH keys first and get their IDs
                var cloudKeyIds: [String] = []
                
                if !selectedSSHKeys.isEmpty {
                    // Get existing SSH keys from provider
                    let existingKeys = try await service.listSSHKeys()
                    
                    // Filter to only valid keys with public key
                    let validKeys = sshKeys.filter { !$0.publicKey.isEmpty }
                    
                    for keyId in selectedSSHKeys {
                        if let sshKey = validKeys.first(where: { $0.id.uuidString == keyId }) {
                            // Check if key already exists on provider by comparing public key content
                            let keyMatches = existingKeys.first { existingKey in
                                // Compare the actual public key content (normalize whitespace)
                                let normalizedExisting = existingKey.publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                let normalizedLocal = sshKey.publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                return normalizedExisting == normalizedLocal
                            }
                            
                            if let existingKey = keyMatches {
                                // Use existing key ID
                                cloudKeyIds.append(existingKey.id)
                            } else if !sshKey.publicKey.isEmpty {
                                // Upload new key
                                let uploadedKey = try await service.addSSHKey(
                                    name: "\(sshKey.name) (Mobile)",
                                    publicKey: sshKey.publicKey
                                )
                                cloudKeyIds.append(uploadedKey.id)
                            }
                        }
                    }
                }
                
                // Generate cloud-init script with SSH keys
                let cloudInitScript = generateCloudInit(with: selectedSSHKeys)
                
                // Create the server
                let server = try await service.createServer(
                    name: serverName,
                    region: selectedRegion,
                    size: selectedSize,
                    image: selectedImage,
                    sshKeyIds: cloudKeyIds,
                    userData: cloudInitScript
                )
                
                await MainActor.run {
                    createdServer = server
                    creationStatus = .polling(serverId: server.id)
                }
                
                // Poll for server to become active
                await pollServerStatus(serverId: server.id, service: service)
                
            } catch {
                await MainActor.run {
                    creationStatus = .failed(error: error.localizedDescription)
                    errorMessage = error.localizedDescription
                    showError = true
                    isProvisioning = false  // End provisioning on error
                }
            }
        }
    }
    
    private func createAndSaveServerRecord(from cloudServer: CloudServer) -> Server {
        // Create a new Server record
        let server = Server(
            name: cloudServer.name,
            host: cloudServer.publicIP ?? "",
            port: 22,
            username: "codeagent",  // Use codeagent user created by cloud-init
            authMethodType: "key"
        )
        
        // Set provider information
        server.providerId = provider.id
        server.providerServerId = cloudServer.id
        
        // Set default projects path for codeagent user
        server.defaultProjectsPath = "/home/codeagent/projects"
        
        // Set initial cloud-init status
        server.cloudInitComplete = false
        server.cloudInitStatus = "running"
        server.cloudInitLastChecked = Date()
        
        // Attach the first selected SSH key if any
        if let firstKeyId = selectedSSHKeys.first,
           let sshKey = sshKeys.first(where: { $0.id.uuidString == firstKeyId }) {
            server.sshKeyId = sshKey.id
        }
        
        // DON'T save to database yet - just prepare the server object
        // We'll save it only when the user takes an action (Continue in background, Add Agent, or Skip)
        print("📦 Server object created but NOT saved to database yet")
        
        return server
    }
    
    private func generateCloudInit(with sshKeyIds: Set<String>) -> String {
        // Get the selected SSH keys
        let validKeys = sshKeys.filter { !$0.publicKey.isEmpty }
        let selectedKeys = sshKeyIds.compactMap { keyId in
            validKeys.first(where: { $0.id.uuidString == keyId })
        }
        
        // Extract public keys from selected SSH keys
        let publicKeys = selectedKeys.map { $0.publicKey }
        
        // Use the template to generate cloud-init configuration
        return CloudInitTemplate.generate(with: publicKeys) ?? ""
    }
    
    private func selectLatestUbuntuImage() -> String {
        // Filter Ubuntu images - check both name and ID for Ubuntu
        let ubuntuImages = availableImages.filter { image in
            let nameLower = image.name.lowercased()
            let idLower = image.id.lowercased()
            return nameLower.contains("ubuntu") || idLower.contains("ubuntu")
        }
        
        // Sort by version number (highest first) - simplified
        let sorted = ubuntuImages.sorted { first, second in
            let firstNameVersion = extractUbuntuVersion(from: first.name)
            let firstIdVersion = extractUbuntuVersion(from: first.id)
            
            let secondNameVersion = extractUbuntuVersion(from: second.name)
            let secondIdVersion = extractUbuntuVersion(from: second.id)
            
            // Use the better version from name or ID
            let firstVersion = (firstNameVersion.major > firstIdVersion.major ||
                               (firstNameVersion.major == firstIdVersion.major && firstNameVersion.minor > firstIdVersion.minor))
                               ? firstNameVersion : firstIdVersion
            
            let secondVersion = (secondNameVersion.major > secondIdVersion.major ||
                                (secondNameVersion.major == secondIdVersion.major && secondNameVersion.minor > secondIdVersion.minor))
                                ? secondNameVersion : secondIdVersion
            
            // Compare versions (e.g., 24.04 > 22.04)
            if firstVersion.major != secondVersion.major {
                return firstVersion.major > secondVersion.major
            }
            return firstVersion.minor > secondVersion.minor
        }
        
        // Return the ID of the latest Ubuntu version
        if let selected = sorted.first {
            print("Selected Ubuntu image: \(selected.name) (id: \(selected.id))")
            return selected.id
        }
        
        // Fallback: if no Ubuntu found, try to find any Linux image
        print("No Ubuntu image found, falling back to any available image")
        return availableImages.first?.id ?? ""
    }
    
    private func extractUbuntuVersion(from name: String) -> (major: Int, minor: Int) {
        // Handle formats like "Ubuntu 24.04 LTS", "ubuntu-24-04-x64", etc.
        let pattern = #"(\d+)[.-](\d+)"#
        
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) {
            if let majorRange = Range(match.range(at: 1), in: name),
               let minorRange = Range(match.range(at: 2), in: name),
               let major = Int(name[majorRange]),
               let minor = Int(name[minorRange]) {
                return (major, minor)
            }
        }
        
        return (0, 0) // Default if no version found
    }
    
    private func pollServerStatus(serverId: String, service: CloudProviderProtocol) async {
        var attempts = 0
        let maxAttempts = 30 // Poll for up to 2.5 minutes (30 * 5 seconds)
        
        // Phase 1: Poll provider API until server is active
        while attempts < maxAttempts && !Task.isCancelled {
            attempts += 1
            
            // Wait 5 seconds between polls
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            
            do {
                if let server = try await service.getServer(id: serverId) {
                    await MainActor.run {
                        createdServer = server
                        provisioningStatus.providerStatus = server.status.lowercased()
                    }
                    
                    if server.status.lowercased() == "active" || server.status.lowercased() == "running" {
                        // Update provider status to show properly
                        await MainActor.run {
                            // Normalize status for UI display
                            if server.status.lowercased() == "running" {
                                provisioningStatus.providerStatus = "running"
                            } else {
                                provisioningStatus.providerStatus = "active"
                            }
                        }
                        
                        // Server is active, create the server record but DON'T save to database
                        if savedServer == nil {
                            print("📝 Creating server record (NOT saving to database) - isProvisioning: \(isProvisioning)")
                            // Create in main actor context
                            await MainActor.run {
                                savedServer = createAndSaveServerRecord(from: server)
                            }
                            print("📦 Server record created in memory, waiting for user action to save")
                        }
                        
                        // Now check cloud-init
                        await MainActor.run {
                            creationStatus = .checkingCloudInit(serverId: serverId)
                            provisioningStatus.cloudInitStatus = "checking"
                        }
                        
                        // Phase 2: Check cloud-init status
                        await checkCloudInitStatus(server: server)
                        return
                    }
                }
            } catch {
                // Continue polling even if one request fails
                print("Poll failed: \(error)")
            }
        }
        
        // If we've exhausted attempts, still check cloud-init if server exists
        if let server = createdServer {
            await MainActor.run {
                creationStatus = .checkingCloudInit(serverId: serverId)
            }
            await checkCloudInitStatus(server: server)
        } else {
            await MainActor.run {
                creationStatus = .failed(error: "Server creation timed out")
                isProvisioning = false  // End provisioning on timeout
            }
        }
    }
    
    private func checkCloudInitStatus(server: CloudServer) async {
        guard let publicIP = server.publicIP else {
            await MainActor.run {
                creationStatus = .failed(error: "No public IP assigned")
                isProvisioning = false  // End provisioning if no IP
            }
            return
        }
        
        // Wait a bit for SSH to be available
        try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
        
        let maxCloudInitAttempts = 120 // Check for up to 20 minutes (120 * 10 seconds)
        var cloudInitAttempts = 0
        
        while cloudInitAttempts < maxCloudInitAttempts && !Task.isCancelled {
            cloudInitAttempts += 1
            
            await MainActor.run {
                provisioningStatus.cloudInitCheckAttempts = cloudInitAttempts
            }
            
            // Try to check cloud-init status via SSH
            if let status = await checkCloudInitViaSSH(host: publicIP) {
                await MainActor.run {
                    // If we got a status, it means SSH is working
                    if provisioningStatus.cloudInitStatus == "checking" {
                        provisioningStatus.cloudInitStatus = "running"
                    }
                    // Update with actual status
                    provisioningStatus.cloudInitStatus = status
                    provisioningStatus.lastChecked = Date()
                }
                
                if status == "done" {
                    // Cloud-init is complete, start proxy installation
                    if let savedServer = savedServer {
                        await MainActor.run {
                            savedServer.cloudInitComplete = true
                            savedServer.cloudInitStatus = "done"
                            savedServer.cloudInitLastChecked = Date()
                            print("✅ Updated in-memory server cloud-init status to done (not saved to DB yet)")
                        }
                        await startProxyInstall(for: savedServer)
                    } else {
                        await MainActor.run {
                            creationStatus = .failed(error: "Missing server record for proxy install")
                            isProvisioning = false
                        }
                    }
                    return
                } else if status == "error" {
                    await MainActor.run {
                        creationStatus = .failed(error: "Cloud-init configuration failed")
                        isProvisioning = false  // End provisioning on cloud-init error
                    }
                    return
                }
            }
            
            // Wait 10 seconds before next check
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
        
        // Check if cancelled
        if Task.isCancelled {
            print("🛑 Cloud-init monitoring cancelled - handing over to background monitor")
            return
        }
        
        // Timeout - but server is still usable, just might not have Claude Code
        await MainActor.run {
            provisioningStatus.cloudInitStatus = "timeout"
            provisioningStatus.proxyInstallStatus = "skipped"
            creationStatus = .success // Allow proceeding anyway
            isProvisioning = false  // End provisioning on timeout
        }
    }
    
    private func checkCloudInitViaSSH(host: String) async -> String? {
        // Use the saved server object if available - it already has all the connection info
        guard let server = savedServer else {
            print("No saved server available for cloud-init check")
            return nil
        }
        
        do {
            // Use the same connection method as ProjectService - much simpler!
            let sshService = SSHService.shared
            let session = try await sshService.connect(to: server, purpose: .cloudInit)
            
            // SSH connection successful
            await MainActor.run {
                provisioningStatus.sshAccessible = true
                // Update status to show we're connected and checking
                if provisioningStatus.cloudInitStatus == "checking" || provisioningStatus.cloudInitStatus == "waiting" {
                    provisioningStatus.cloudInitStatus = "running"
                }
            }
            
            // Run cloud-init status command
            let output = try await session.execute("sudo cloud-init status")
            
            // Parse the output
            if output.contains("status: done") {
                return "done"
            } else if output.contains("status: running") {
                return "running"
            } else if output.contains("status: error") {
                return "error"
            } else if output.contains("status: disabled") {
                // Cloud-init is disabled, consider it done
                return "done"
            }
            
            // If we can connect but get unexpected output, still in progress
            return "running"
            
        } catch {
            print("SSH check failed: \(error)")
            // SSH connection failed, server might not be ready yet
            await MainActor.run {
                provisioningStatus.sshAccessible = false
            }
            return nil
        }
    }

    @MainActor
    private func startProxyInstall(for server: Server) async {
        proxyInstallTask?.cancel()
        proxyInstallLogs = []
        proxyInstallError = nil
        provisioningStatus.proxyInstallStatus = "running"
        creationStatus = .installingProxy(serverId: server.providerServerId ?? server.id.uuidString)

        proxyInstallTask = Task {
            do {
                try await ProxyInstallerService.shared.installProxy(on: server) { line in
                    Task { @MainActor in
                        appendProxyInstallLog(line)
                    }
                }
                await MainActor.run {
                    provisioningStatus.proxyInstallStatus = "done"
                    creationStatus = .success
                    isProvisioning = false
                    print("Proxy install complete - isProvisioning set to false")
                }
            } catch {
                await MainActor.run {
                    provisioningStatus.proxyInstallStatus = "error"
                    proxyInstallError = error.localizedDescription
                }
            }
        }
    }

    private func retryProxyInstall() {
        guard let server = savedServer else { return }
        Task { @MainActor in
            await startProxyInstall(for: server)
        }
    }

    private func skipProxyInstall() {
        provisioningStatus.proxyInstallStatus = "skipped"
        proxyInstallError = nil
        creationStatus = .success
        isProvisioning = false
    }

    @MainActor
    private func appendProxyInstallLog(_ line: String) {
        proxyInstallLogs.append(line)
        let maxLines = 200
        if proxyInstallLogs.count > maxLines {
            proxyInstallLogs.removeFirst(proxyInstallLogs.count - maxLines)
        }
    }
}

private extension CreateCloudServerView.CreationStatus {
    var isPolling: Bool {
        if case .polling = self {
            return true
        }
        return false
    }
    
    var isCheckingCloudInit: Bool {
        if case .checkingCloudInit = self {
            return true
        }
        return false
    }

    var isInstallingProxy: Bool {
        if case .installingProxy = self {
            return true
        }
        return false
    }
    
    var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}

// MARK: - Size Selector Sheet

struct SizeSelectorSheet: View {
    let availableSizes: [(id: String, name: String, description: String)]
    @Binding var selectedSize: String
    let providerType: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(availableSizes, id: \.id) { size in
                    Button(action: {
                        selectedSize = size.id
                        dismiss()
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(size.name)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                
                                // Parse and format the description
                                if let details = parseDescription(size.description) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 12) {
                                            Label(details.cpu, systemImage: "cpu")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Label(details.ram, systemImage: "memorychip")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        HStack(spacing: 12) {
                                            Label(details.storage, systemImage: "internaldrive")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Text(details.price)
                                                .font(.caption)
                                                .fontWeight(.semibold)
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                } else {
                                    Text(size.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            
                            Spacer()
                            
                            if selectedSize == size.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.accentColor)
                                    .font(.title2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("Select Server Size")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func parseDescription(_ description: String) -> (cpu: String, ram: String, storage: String, price: String)? {
        // Parse description like "2 vCPUs • 4GB RAM • 80GB SSD • $24/mo"
        let components = description.split(separator: "•").map { $0.trimmingCharacters(in: .whitespaces) }
        
        if components.count >= 4 {
            return (
                cpu: String(components[0]),
                ram: String(components[1]),
                storage: String(components[2]),
                price: String(components[3])
            )
        }
        
        return nil
    }
}

// MARK: - Progress Step View

struct ProgressStep: View {
    let title: String
    let isComplete: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isComplete ? .green : .gray.opacity(0.3))
                .font(.system(size: 20))
            
            Text(title)
                .font(.subheadline)
                .foregroundColor(isComplete ? .primary : .secondary)
            
            Spacer()
        }
    }
}

#Preview {
    CreateCloudServerView(
        provider: ServerProvider(providerType: "digitalocean", name: "DigitalOcean"),
        dismissAll: nil,
        isProvisioning: .constant(false),
        onComplete: {}
    )
    .modelContainer(for: [SSHKey.self], inMemory: true)
}
