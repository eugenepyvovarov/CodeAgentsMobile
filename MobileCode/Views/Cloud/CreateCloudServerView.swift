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
    @State private var savedServer: Server?
    @State private var projectCreationRoute: CloudServerProjectCreationRoute?
    
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
    @State private var runtimeSetupLogs: [String] = []
    @State private var runtimeSetupError: String?
    @State private var runtimeVerificationTask: Task<Void, Never>?
    @State private var pendingLocalServerID: UUID?
    
    // Server provisioning status tracking
    @State private var provisioningStatus = ServerProvisioningStatus()
    
    struct ServerProvisioningStatus {
        var providerStatus: String = "new" // "new", "active", "error" from API
        var cloudInitStatus: String = "waiting" // "waiting", "checking", "running", "done", "error"
        var lastChecked: Date = Date()
        var sshAccessible: Bool = false
        var cloudInitCheckAttempts: Int = 0
        var runtimeSetupStatus: String = "waiting" // "waiting", "running", "done", "error", "skipped"
    }
    
    enum CreationStatus: Equatable {
        case idle
        case creating
        case polling(serverId: String)
        case checkingCloudInit(serverId: String)
        case verifyingRuntime(serverId: String)
        case success
        case failed(error: String)
    }
    
    var body: some View {
        NavigationStack {
            Group {
                if isLoadingOptions {
                    ProgressView("Loading options...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if creationStatus == .creating || creationStatus.isPolling || creationStatus.isCheckingCloudInit || creationStatus.isVerifyingRuntime || creationStatus == .success {
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
                        .accessibilityIdentifier("cloud-server-create-button")
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
                guard !hasInFlightProvisioning else {
                    print("Keeping server provisioning tasks alive while the create-server view disappears")
                    return
                }

                if serverCreationTask != nil {
                    serverCreationTask?.cancel()
                    serverCreationTask = nil
                    print("Cancelled idle server creation task on view disappear")
                }
                if runtimeVerificationTask != nil {
                    runtimeVerificationTask?.cancel()
                    runtimeVerificationTask = nil
                    print("Cancelled idle OpenCode runtime verification task on view disappear")
                }
                if savedServer == nil, let pendingLocalServerID {
                    try? KeychainManager.shared.deleteOpenCodeServerCredentials(for: pendingLocalServerID)
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
            .sheet(item: $projectCreationRoute) { route in
                if let server = savedServer, server.id == route.serverID {
                    AddProjectSheet(
                        preselectedServer: server,
                        onProjectCreated: {
                            // When project is successfully created, dismiss all views
                            projectCreationRoute = nil
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
                            projectCreationRoute = nil
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
                } else {
                    MissingCreatedServerSheet()
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
                    .accessibilityIdentifier("cloud-server-name-field")
                
                Picker("Region", selection: $selectedRegion) {
                    Text("Select Region").tag("")
                    ForEach(availableRegions, id: \.id) { region in
                        Text(region.name).tag(region.id)
                    }
                }
                .accessibilityIdentifier("cloud-server-region-picker")
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
                    .accessibilityIdentifier("cloud-server-size-button")
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
                        .accessibilityIdentifier("cloud-server-generate-key-button")
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
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("cloud-server-ssh-key-\(key.name.cloudAccessibilityIdentifierFragment)")
                    }
                    
                    Button(action: { showGenerateKey = true }) {
                        Label("Generate New Key", systemImage: "plus.circle")
                            .font(.footnote)
                    }
                    .accessibilityIdentifier("cloud-server-generate-key-button")
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
                Text(creationStatus == .success ? "Server ready!" : creationStatus.isVerifyingRuntime ? "Verifying OpenCode and daemon..." : "Creating your server")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .animation(.easeInOut(duration: 0.3), value: creationStatus)
                
                if creationStatus == .success {
                    Text("Your server is now active and ready to use")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                } else if creationStatus.isVerifyingRuntime {
                    Text("Checking the OpenCode runtime on your server")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Text("This typically takes 1-2 minutes")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                } else if case .checkingCloudInit = creationStatus {
                    Text("Installing packages and configuring OpenCode...")
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

                        // OpenCode Runtime
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "bolt.circle")
                                    .foregroundColor(.blue)
                                Text("OpenCode Runtime")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Spacer()
                                if provisioningStatus.runtimeSetupStatus == "done" {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                } else if provisioningStatus.runtimeSetupStatus == "error" {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundColor(.red)
                                } else if provisioningStatus.runtimeSetupStatus == "skipped" {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.orange)
                                } else if provisioningStatus.runtimeSetupStatus != "waiting" {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                }
                            }
                            
                            HStack(spacing: 8) {
                                ProgressStep(
                                    title: provisioningStatus.runtimeSetupStatus == "waiting" ? "Waiting" :
                                           provisioningStatus.runtimeSetupStatus == "running" ? "Verifying" :
                                           provisioningStatus.runtimeSetupStatus == "done" ? "Ready" :
                                           provisioningStatus.runtimeSetupStatus == "skipped" ? "Skipped" : "Error",
                                    isComplete: provisioningStatus.runtimeSetupStatus == "done"
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

            if !runtimeSetupLogs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Runtime Check Output")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    ScrollView {
                        Text(runtimeSetupLogs.joined(separator: "\n"))
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

            if let runtimeSetupError = runtimeSetupError {
                Text(runtimeSetupError)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
            
            // Action buttons based on status
            if provisioningStatus.runtimeSetupStatus == "error" {
                VStack(spacing: 12) {
                    Button("Retry Check") {
                        retryRuntimeVerification()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("cloud-server-retry-runtime-button")
                    
                    Button("Skip for Now") {
                        skipRuntimeVerification()
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("cloud-server-skip-button")
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: provisioningStatus.runtimeSetupStatus)
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
                    .accessibilityIdentifier("cloud-server-add-agent-button")
                    
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
                    .accessibilityIdentifier("cloud-server-skip-button")
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
                .accessibilityIdentifier("cloud-server-add-agent-button")
                
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
                .accessibilityIdentifier("cloud-server-skip-button")
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

        guard let server = savedServer else {
            errorMessage = "Server record is not ready yet. Please wait a moment and try again."
            showError = true
            return
        }

        // Save the server to database when user chooses to add a project.
        modelContext.insert(server)
        do {
            try modelContext.save()
            print("💾 Server saved to database on 'Add Agent'")
        } catch {
            errorMessage = "Failed to save server: \(error.localizedDescription)"
            showError = true
            return
        }
        
        // Navigate to project creation
        projectCreationRoute = CloudServerProjectCreationRoute.route(for: server.id)
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

            applyUITestAutofillIfNeeded()
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

    private func applyUITestAutofillIfNeeded() {
        let processInfo = ProcessInfo.processInfo
        guard processInfo.arguments.contains("--ui-testing"),
              processInfo.environment["MOBILECODE_E2E_AUTOFILL_CLOUD_SERVER"] == "1" else {
            return
        }

        let environment = processInfo.environment
        if serverName.isEmpty, let name = environment["MOBILECODE_E2E_SERVER_NAME"], !name.isEmpty {
            serverName = name
        }

        if selectedRegion.isEmpty {
            if let requestedRegion = environment["MOBILECODE_E2E_REGION"], !requestedRegion.isEmpty,
               let matchedRegion = availableRegions.first(where: {
                   $0.id == requestedRegion || $0.name.localizedCaseInsensitiveContains(requestedRegion)
               }) {
                selectedRegion = matchedRegion.id
            } else {
                selectedRegion = availableRegions.first?.id ?? ""
            }
        }

        if selectedSize.isEmpty {
            if let requestedSize = environment["MOBILECODE_E2E_SIZE"], !requestedSize.isEmpty,
               let matchedSize = filteredSizes.first(where: {
                   $0.id == requestedSize || $0.name.localizedCaseInsensitiveContains(requestedSize)
               }) {
                selectedSize = matchedSize.id
            } else {
                selectedSize = preferredUITestSize(in: filteredSizes)?.id ?? filteredSizes.first?.id ?? ""
            }
        }

        seedUITestSSHKeyIfNeeded(environment: environment)
    }

    private func preferredUITestSize(
        in sizes: [(id: String, name: String, description: String)]
    ) -> (id: String, name: String, description: String)? {
        if provider.providerType == "digitalocean" {
            let preferredSlugs = [
                "s-1vcpu-1gb",
                "s-1vcpu-2gb",
                "s-2vcpu-2gb"
            ]
            if let match = sizes.first(where: { size in
                preferredSlugs.contains { size.id.localizedCaseInsensitiveContains($0) }
            }) {
                return match
            }
        }

        if provider.providerType == "hetzner" {
            let preferredSlugs = ["cx22", "cpx11", "cx32"]
            if let match = sizes.first(where: { size in
                preferredSlugs.contains { size.id.localizedCaseInsensitiveContains($0) }
            }) {
                return match
            }
        }

        return sizes.first { size in
            !size.id.localizedCaseInsensitiveContains("512mb")
                && !size.description.localizedCaseInsensitiveContains("512MB")
        }
    }

    private func seedUITestSSHKeyIfNeeded(environment: [String: String]) {
        guard environment["MOBILECODE_E2E_AUTOUSE_HOST_SSH_KEY"] == "1",
              let keyName = environment["MOBILECODE_E2E_SSH_KEY_NAME"], !keyName.isEmpty,
              let publicKey = environment["MOBILECODE_E2E_SSH_PUBLIC_KEY"], !publicKey.isEmpty,
              let privateKeyBase64 = environment["MOBILECODE_E2E_SSH_PRIVATE_KEY_B64"], !privateKeyBase64.isEmpty else {
            return
        }

        if let existingKey = sshKeys.first(where: { $0.name == keyName }) {
            selectedSSHKeys.insert(existingKey.id.uuidString)
            E2EProvisioningDebugLog.append("selected seeded SSH key \(keyName)")
            return
        }

        guard let privateKeyData = Data(base64Encoded: privateKeyBase64) else {
            E2EProvisioningDebugLog.append("failed to decode seeded SSH private key for \(keyName)")
            return
        }

        do {
            let sshKey = SSHKey(
                name: keyName,
                keyType: "Ed25519",
                privateKeyIdentifier: UUID().uuidString
            )
            sshKey.publicKey = publicKey
            try KeychainManager.shared.storeSSHKey(privateKeyData, for: sshKey.id)
            modelContext.insert(sshKey)
            try modelContext.save()
            selectedSSHKeys.insert(sshKey.id.uuidString)
            E2EProvisioningDebugLog.append("seeded and selected host SSH key \(keyName)")
        } catch {
            E2EProvisioningDebugLog.append("failed to seed host SSH key \(keyName): \(error.localizedDescription)")
        }
    }
    
    private func createServer() {
        creationStatus = .creating
        isProvisioning = true  // Start provisioning
        print("🚀 Starting server provisioning - isProvisioning set to true")
        E2EProvisioningDebugLog.reset()
        E2EProvisioningDebugLog.append("starting server provisioning name=\(serverName) region=\(selectedRegion) size=\(selectedSize)")
        provisioningStatus = ServerProvisioningStatus()
        runtimeSetupLogs = []
        runtimeSetupError = nil
        runtimeVerificationTask?.cancel()
        runtimeVerificationTask = nil
        let localServerID = UUID()
        pendingLocalServerID = localServerID

        let openCodeServerPassword: String
        do {
            openCodeServerPassword = try OpenCodeServerPasswordGenerator.generate()
            try KeychainManager.shared.storeOpenCodeServerCredentials(
                username: OpenCodeServerProvisioning.username,
                password: openCodeServerPassword,
                for: localServerID
            )
            E2EProvisioningDebugLog.append("stored generated OpenCode server auth for pending local server id")
        } catch {
            creationStatus = .failed(error: error.localizedDescription)
            errorMessage = error.localizedDescription
            showError = true
            isProvisioning = false
            return
        }
        
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
                let cloudInitScript = generateCloudInit(
                    with: selectedSSHKeys,
                    openCodeServerPassword: openCodeServerPassword
                )
                E2EProvisioningDebugLog.append(
                    "generated cloud-init selectedSSHKeys=\(selectedSSHKeys.count) cloudKeyIds=\(cloudKeyIds.count)"
                )
                
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
                E2EProvisioningDebugLog.append("created cloud server id=\(server.id) status=\(server.status)")
                
                // Poll for server to become active
                await pollServerStatus(
                    serverId: server.id,
                    service: service,
                    openCodeServerPassword: openCodeServerPassword
                )
                
            } catch {
                try? KeychainManager.shared.deleteOpenCodeServerCredentials(for: localServerID)
                E2EProvisioningDebugLog.append("server creation failed: \(error.localizedDescription)")
                await MainActor.run {
                    creationStatus = .failed(error: error.localizedDescription)
                    errorMessage = error.localizedDescription
                    showError = true
                    isProvisioning = false  // End provisioning on error
                }
            }
        }
    }

    private var hasInFlightProvisioning: Bool {
        isProvisioning
            || creationStatus == .creating
            || creationStatus.isPolling
            || creationStatus.isCheckingCloudInit
            || creationStatus.isVerifyingRuntime
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
        if let pendingLocalServerID {
            server.id = pendingLocalServerID
        }
        
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
    
    private func generateCloudInit(with sshKeyIds: Set<String>, openCodeServerPassword: String) -> String {
        // Get the selected SSH keys
        let validKeys = sshKeys.filter { !$0.publicKey.isEmpty }
        let selectedKeys = sshKeyIds.compactMap { keyId in
            validKeys.first(where: { $0.id.uuidString == keyId })
        }
        
        // Extract public keys from selected SSH keys
        let publicKeys = selectedKeys.map { $0.publicKey }
        
        // Use the template to generate cloud-init configuration
        return CloudInitTemplate.generate(
            with: publicKeys,
            openCodeServerPassword: openCodeServerPassword
        ) ?? ""
    }
    
    private func selectLatestUbuntuImage() -> String {
        let selectedImageId = CloudImageSelector.preferredUbuntuImage(from: availableImages)
        if let selected = availableImages.first(where: { $0.id == selectedImageId }) {
            print("Selected Ubuntu image: \(selected.name) (id: \(selected.id))")
        } else if selectedImageId.isEmpty {
            print("No Ubuntu image found, falling back to any available image")
        }

        return selectedImageId
    }
    
    private func pollServerStatus(
        serverId: String,
        service: CloudProviderProtocol,
        openCodeServerPassword: String
    ) async {
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
                    E2EProvisioningDebugLog.append(
                        "provider poll attempt=\(attempts) status=\(server.status) publicIP=\(server.publicIP ?? "none")"
                    )
                    
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
                                let preparedServer = createAndSaveServerRecord(from: server)
                                do {
                                    try KeychainManager.shared.storeOpenCodeServerCredentials(
                                        username: OpenCodeServerProvisioning.username,
                                        password: openCodeServerPassword,
                                        for: preparedServer.id
                                    )
                                    E2EProvisioningDebugLog.append(
                                        "stored generated OpenCode server auth for prepared server id"
                                    )
                                } catch {
                                    E2EProvisioningDebugLog.append(
                                        "failed to store generated OpenCode server auth for prepared server id: \(error.localizedDescription)"
                                    )
                                }
                                savedServer = preparedServer
                            }
                            print("📦 Server record created in memory, waiting for user action to save")
                        }
                        E2EProvisioningDebugLog.append("cloud server active; starting cloud-init checks")
                        
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
                E2EProvisioningDebugLog.append("provider poll attempt=\(attempts) failed: \(error.localizedDescription)")
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
            E2EProvisioningDebugLog.append("cloud-init check failed: no public IP")
            await MainActor.run {
                creationStatus = .failed(error: "No public IP assigned")
                isProvisioning = false  // End provisioning if no IP
            }
            return
        }
        
        // Wait a bit for SSH to be available
        E2EProvisioningDebugLog.append("waiting for SSH before cloud-init checks publicIP=\(publicIP)")
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
                E2EProvisioningDebugLog.append("cloud-init attempt=\(cloudInitAttempts) status=\(status)")
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
                    // Cloud-init is complete, verify OpenCode runtime health
                    if let savedServer = savedServer {
                        await MainActor.run {
                            savedServer.cloudInitComplete = true
                            savedServer.cloudInitStatus = "done"
                            savedServer.cloudInitLastChecked = Date()
                            print("✅ Updated in-memory server cloud-init status to done (not saved to DB yet)")
                        }
                        await startRuntimeVerification(for: savedServer)
                    } else {
                        await MainActor.run {
                            creationStatus = .failed(error: "Missing server record for OpenCode runtime check")
                            isProvisioning = false
                        }
                    }
                    return
                } else if status == "error" {
                    E2EProvisioningDebugLog.append("cloud-init failed with error status")
                    await MainActor.run {
                        let details = runtimeSetupError.map { "\n\n\($0)" } ?? ""
                        let message = "Cloud-init configuration failed\(details)"
                        creationStatus = .failed(error: message)
                        errorMessage = message
                        showError = true
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
            E2EProvisioningDebugLog.append("cloud-init monitoring cancelled")
            return
        }
        
        // Timeout - but server is still usable, just might not have OpenCode ready yet
        await MainActor.run {
            provisioningStatus.cloudInitStatus = "timeout"
            provisioningStatus.runtimeSetupStatus = "skipped"
            creationStatus = .success // Allow proceeding anyway
            isProvisioning = false  // End provisioning on timeout
        }
        E2EProvisioningDebugLog.append("cloud-init monitoring timed out")
    }
    
    private func checkCloudInitViaSSH(host: String) async -> String? {
        // Use the saved server object if available - it already has all the connection info
        guard let server = savedServer else {
            print("No saved server available for cloud-init check")
            E2EProvisioningDebugLog.append("cloud-init SSH check skipped: no saved server")
            return nil
        }
        
        do {
            // Use the same connection method as ProjectService - much simpler!
            let sshService = SSHService.shared
            let session = try await sshService.connect(to: server, purpose: .cloudInit)
            defer { session.disconnect() }
            
            // SSH connection successful
            await MainActor.run {
                provisioningStatus.sshAccessible = true
                // Update status to show we're connected and checking
                if provisioningStatus.cloudInitStatus == "checking" || provisioningStatus.cloudInitStatus == "waiting" {
                    provisioningStatus.cloudInitStatus = "running"
                }
            }
            
            let output = try await session.execute(CloudInitStatus.statusCommand)
            let status = CloudInitStatus.parse(output)
            E2EProvisioningDebugLog.append(
                "cloud-init raw status=\(status) output=\(CloudInitStatus.redacted(output).prefix(1200))"
            )

            if status == "error" {
                let diagnostics = (try? await session.execute(CloudInitStatus.diagnosticsCommand)) ?? output
                let clippedDiagnostics = CloudInitStatus.clippedDiagnostics(diagnostics)
                E2EProvisioningDebugLog.append("cloud-init diagnostics=\(clippedDiagnostics)")
                await MainActor.run {
                    runtimeSetupError = clippedDiagnostics
                    runtimeSetupLogs = clippedDiagnostics
                        .split(whereSeparator: \.isNewline)
                        .suffix(80)
                        .map(String.init)
                }
            }

            return status
            
        } catch {
            print("SSH check failed: \(error)")
            E2EProvisioningDebugLog.append("cloud-init SSH check failed host=\(host): \(error.localizedDescription)")
            // SSH connection failed, server might not be ready yet
            await MainActor.run {
                provisioningStatus.sshAccessible = false
            }
            return nil
        }
    }

    @MainActor
    private func startRuntimeVerification(for server: Server) async {
        runtimeVerificationTask?.cancel()
        runtimeSetupLogs = []
        runtimeSetupError = nil
        provisioningStatus.runtimeSetupStatus = "running"
        creationStatus = .verifyingRuntime(serverId: server.providerServerId ?? server.id.uuidString)
        E2EProvisioningDebugLog.append(
            "starting OpenCode runtime verification hasAuth=\(KeychainManager.shared.hasOpenCodeServerPassword(for: server.id))"
        )

        runtimeVerificationTask = Task {
            do {
                let status = try await OpenCodeInstallerService.shared.verifyRuntime(on: server) { line in
                    Task { @MainActor in
                        appendRuntimeSetupLog(line)
                    }
                }
                await MainActor.run {
                    provisioningStatus.runtimeSetupStatus = "done"
                    creationStatus = .success
                    isProvisioning = false
                    print("OpenCode runtime verified - isProvisioning set to false")
                }
                E2EProvisioningDebugLog.append(
                    "OpenCode runtime verification succeeded state=\(status.state) foregroundBlocked=\(status.blocksForegroundChat)"
                )
            } catch {
                E2EProvisioningDebugLog.append("OpenCode runtime verification failed: \(error.localizedDescription)")
                await MainActor.run {
                    provisioningStatus.runtimeSetupStatus = "error"
                    runtimeSetupError = error.localizedDescription
                }
            }
        }
    }

    private func retryRuntimeVerification() {
        guard let server = savedServer else { return }
        Task { @MainActor in
            await startRuntimeVerification(for: server)
        }
    }

    private func skipRuntimeVerification() {
        provisioningStatus.runtimeSetupStatus = "skipped"
        runtimeSetupError = nil
        creationStatus = .success
        isProvisioning = false
    }

    @MainActor
    private func appendRuntimeSetupLog(_ line: String) {
        E2EProvisioningDebugLog.append("runtime: \(line)")
        runtimeSetupLogs.append(line)
        let maxLines = 200
        if runtimeSetupLogs.count > maxLines {
            runtimeSetupLogs.removeFirst(runtimeSetupLogs.count - maxLines)
        }
    }
}

extension String {
    var cloudAccessibilityIdentifierFragment: String {
        let allowed = CharacterSet.alphanumerics
        let scalars = unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(String(scalar).lowercased()) : "-"
        }
        let collapsed = String(scalars).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "unnamed" : collapsed
    }
}

private struct MissingCreatedServerSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Server Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text("The new server record is no longer available.")
            } actions: {
                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .navigationTitle("Add Agent")
            .navigationBarTitleDisplayMode(.inline)
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

    var isVerifyingRuntime: Bool {
        if case .verifyingRuntime = self {
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
