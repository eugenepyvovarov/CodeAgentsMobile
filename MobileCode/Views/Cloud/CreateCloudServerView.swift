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
    
    @Environment(\.dismiss) var dismiss
    
    init(provider: ServerProvider, dismissAll: (() -> Void)? = nil, isProvisioning: Binding<Bool> = .constant(false), onComplete: @escaping () -> Void) {
        self.provider = provider
        self.dismissAll = dismissAll
        self._isProvisioning = isProvisioning
        self.onComplete = onComplete
    }
    @Environment(\.modelContext) var modelContext
    @Query var sshKeys: [SSHKey]
    @State var savedServer: Server?
    @State var projectCreationRoute: CloudServerProjectCreationRoute?
    
    // Form fields
    @State var serverName = ""
    @State var selectedRegion = ""
    @State var selectedSize = ""
    @State var selectedImage = "" // Auto-selected, not shown in UI
    @State var selectedProject = "" // For DigitalOcean
    @State var selectedSSHKeys: Set<String> = []
    
    // Available options (fetched from API)
    @State var availableRegions: [(id: String, name: String)] = []
    @State var availableSizes: [(id: String, name: String, description: String)] = []
    @State var allDigitalOceanSizes: [(id: String, name: String, description: String, regions: [String])] = []
    @State var availableImages: [(id: String, name: String)] = []
    @State var availableProjects: [(id: String, name: String)] = [] // For DigitalOcean
    
    // State management
    @State var isLoadingOptions = true
    @State var isCreating = false
    @State var creationStatus: CreationStatus = .idle
    @State var errorMessage: String?
    @State var showError = false
    @State var createdServer: CloudServer?
    @State var showGenerateKey = false
    @State var showSizeSelector = false
    @State var serverCreationTask: Task<Void, Never>?
    @State var runtimeSetupLogs: [String] = []
    @State var runtimeSetupError: String?
    @State var runtimeVerificationTask: Task<Void, Never>?
    @State var pendingLocalServerID: UUID?
    
    // Server provisioning status tracking
    @State var provisioningStatus = ServerProvisioningStatus()
    
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
    
    var filteredSizes: [(id: String, name: String, description: String)] {
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
    
    func addProject() {
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
    
    private func selectLatestUbuntuImage() -> String {
        let selectedImageId = CloudImageSelector.preferredUbuntuImage(from: availableImages)
        if let selected = availableImages.first(where: { $0.id == selectedImageId }) {
            print("Selected Ubuntu image: \(selected.name) (id: \(selected.id))")
        } else if selectedImageId.isEmpty {
            print("No Ubuntu image found, falling back to any available image")
        }

        return selectedImageId
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

#Preview {
    CreateCloudServerView(
        provider: ServerProvider(providerType: "digitalocean", name: "DigitalOcean"),
        dismissAll: nil,
        isProvisioning: .constant(false),
        onComplete: {}
    )
    .modelContainer(for: [SSHKey.self], inMemory: true)
}
