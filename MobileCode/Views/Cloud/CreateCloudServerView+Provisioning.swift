//
//  CreateCloudServerView+Provisioning.swift
//  CodeAgentsMobile
//
//  Async create / poll / cloud-init / runtime verification for CreateCloudServerView.
//

import SwiftUI
import SwiftData

extension CreateCloudServerView {
    var hasInFlightProvisioning: Bool {
        isProvisioning
            || creationStatus == .creating
            || creationStatus.isPolling
            || creationStatus.isCheckingCloudInit
            || creationStatus.isVerifyingRuntime
    }
    
    func createServer() {
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
    
    func createAndSaveServerRecord(from cloudServer: CloudServer) -> Server {
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
    
    func generateCloudInit(with sshKeyIds: Set<String>, openCodeServerPassword: String) -> String {
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
    
    func pollServerStatus(
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
    
    func checkCloudInitStatus(server: CloudServer) async {
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
    
    func checkCloudInitViaSSH(host: String) async -> String? {
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
    func startRuntimeVerification(for server: Server) async {
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

    func retryRuntimeVerification() {
        guard let server = savedServer else { return }
        Task { @MainActor in
            await startRuntimeVerification(for: server)
        }
    }

    func skipRuntimeVerification() {
        provisioningStatus.runtimeSetupStatus = "skipped"
        runtimeSetupError = nil
        creationStatus = .success
        isProvisioning = false
    }

    @MainActor
    func appendRuntimeSetupLog(_ line: String) {
        E2EProvisioningDebugLog.append("runtime: \(line)")
        runtimeSetupLogs.append(line)
        let maxLines = 200
        if runtimeSetupLogs.count > maxLines {
            runtimeSetupLogs.removeFirst(runtimeSetupLogs.count - maxLines)
        }
    }
}

extension CreateCloudServerView.CreationStatus {
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
