//
//  CreateCloudServerView+Progress.swift
//  CodeAgentsMobile
//
//  Provisioning progress and success UI for CreateCloudServerView.
//

import SwiftUI
import SwiftData

extension CreateCloudServerView {
    var creationProgressView: some View {
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
    
    var successView: some View {
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
}
