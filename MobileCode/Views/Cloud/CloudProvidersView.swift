//
//  CloudProvidersView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-08-12.
//

import SwiftUI
import SwiftData
import UIKit

struct CloudProvidersView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedProviderType: String = "digitalocean"
    @State private var showAddProvider = false
    
    // Optional completion handler for when a provider is added
    var onProviderAdded: (() -> Void)?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Provider selection
                ScrollView {
                    VStack(spacing: 16) {
                        Text("Choose a cloud provider to connect")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.top)
                        
                        // Available providers to add
                        ProviderCard(
                            providerType: "digitalocean",
                            displayName: "DigitalOcean",
                            isConnected: false,
                            isSelected: selectedProviderType == "digitalocean",
                            onTap: {
                                selectedProviderType = "digitalocean"
                            }
                        )
                        
                        ProviderCard(
                            providerType: "hetzner",
                            displayName: "Hetzner Cloud",
                            isConnected: false,
                            isSelected: selectedProviderType == "hetzner",
                            onTap: {
                                selectedProviderType = "hetzner"
                            }
                        )
                    }
                    .padding()
                }
                
                Spacer()
                
                // Continue button at bottom
                Button(action: {
                    showAddProvider = true
                }) {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding()
            }
            .navigationTitle("Add Cloud Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showAddProvider) {
                AddCloudProviderView(
                    preselectedType: selectedProviderType,
                    onProviderAdded: {
                        // Dismiss this view and call the completion handler if provided
                        if let onProviderAdded = onProviderAdded {
                            dismiss()
                            onProviderAdded()
                        }
                    }
                )
            }
        }
    }
}

// MARK: - Provider Card

struct ProviderCard: View {
    var provider: ServerProvider?
    var providerType: String?
    var displayName: String?
    let isConnected: Bool
    var isSelected: Bool = false
    var onTap: (() -> Void)?
    var onDelete: (() -> Void)?
    
    private var actualProviderType: String {
        provider?.providerType ?? providerType ?? ""
    }
    
    private var actualDisplayName: String {
        if let provider = provider {
            return provider.name
        }
        return displayName ?? ""
    }
    
    private var icon: String {
        actualProviderType == "digitalocean" ? "drop.fill" : "server.rack"
    }
    
    private var iconColor: Color {
        actualProviderType == "digitalocean" ? .blue : .orange
    }
    
    private var providerLabel: String {
        if !isConnected {
            return actualDisplayName.isEmpty ? 
                (actualProviderType == "digitalocean" ? "DigitalOcean" : "Hetzner Cloud") : 
                actualDisplayName
        }
        return actualProviderType == "digitalocean" ? "DigitalOcean" : "Hetzner Cloud"
    }
    
    var body: some View {
        HStack {
            // Icon
            ProviderLogo(providerType: actualProviderType, size: 50)
            
            // Provider info
            VStack(alignment: .leading, spacing: 4) {
                Text(providerLabel)
                    .font(.headline)
            }
            
            Spacer()
            
            // Status or action
            if isConnected {
                // Use same pill style as CloudInitStatusBadge
                Text("Connected")
                    .font(.caption2)
                    .foregroundColor(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.15))
                    .cornerRadius(4)
            } else if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let onTap = onTap {
                onTap()
            }
        }
        .contextMenu {
            if isConnected, let onDelete = onDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }
}

struct AddCloudProviderView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @Query private var existingProviders: [ServerProvider]
    
    let preselectedType: String?
    var onProviderAdded: (() -> Void)?
    
    @State private var selectedProvider: ProviderType = .digitalOcean
    @State private var apiToken = ""
    @State private var providerName = ""
    @State private var isValidating = false
    @State private var errorMessage: String?
    @State private var showError = false
    
    init(preselectedType: String? = nil, onProviderAdded: (() -> Void)? = nil) {
        self.preselectedType = preselectedType
        self.onProviderAdded = onProviderAdded
    }
    
    enum ProviderType: String, CaseIterable {
        case digitalOcean = "digitalocean"
        case hetzner = "hetzner"
        
        var displayName: String {
            switch self {
            case .digitalOcean: return "DigitalOcean"
            case .hetzner: return "Hetzner Cloud"
            }
        }
        
        var referralLink: String {
            switch self {
            case .digitalOcean: return "https://m.do.co/c/b7bf720b7a4c"
            case .hetzner: return "https://hetzner.cloud/?ref=1ESM3gU7EVGt"
            }
        }
        
        var referralText: String {
            switch self {
            case .digitalOcean: return "New users get $200 credit for 60 days"
            case .hetzner: return "New users get €20 cloud credits"
            }
        }
        
        var tokenHelp: String {
            switch self {
            case .digitalOcean:
                return "Control Panel → API → Tokens → Personal Access Token (scopes: read or read-write)"
            case .hetzner:
                return "Console → Project → Security → API Tokens (Read-only or Read & Write)"
            }
        }
    }
    
    private var availableProviders: [ProviderType] {
        ProviderType.allCases
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    // Show the preselected provider
                    HStack {
                        ProviderIcon(
                            providerType: selectedProvider.rawValue,
                            size: 20,
                            color: selectedProvider == .digitalOcean ? .blue : .orange
                        )
                        Text(selectedProvider.displayName)
                            .font(.headline)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .onAppear {
                        // Set the selected provider based on preselection
                        if let preselectedType = preselectedType,
                           let type = ProviderType(rawValue: preselectedType) {
                            selectedProvider = type
                            // Generate unique name if multiple accounts exist
                            let existingCount = existingProviders.filter { $0.providerType == type.rawValue }.count
                            if existingCount > 0 {
                                providerName = "\(type.displayName) #\(existingCount + 1)"
                            } else {
                                providerName = type.displayName
                            }
                        }
                    }
                    
                    // Referral section
                    VStack(alignment: .leading, spacing: 8) {
                        Label(selectedProvider.referralText, systemImage: "gift")
                            .font(.subheadline)
                            .foregroundColor(.blue)
                        
                        Button(action: openReferralLink) {
                            Label("Sign up & get bonus", systemImage: "arrow.up.right.square")
                                .font(.subheadline)
                        }
                        
                        Text("Terms may change. Check current terms on registration page.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                Section("Configuration") {
                    TextField("Display Name", text: $providerName)
                        .autocapitalization(.none)
                    
                    SecureField("API Token", text: $apiToken)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    
                    Text(selectedProvider.tokenHelp)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section {
                    Button(action: validateAndSave) {
                        if isValidating {
                            HStack {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                                    .scaleEffect(0.8)
                                Text("Validating...")
                            }
                        } else {
                            Text("Connect Account")
                        }
                    }
                    .disabled(apiToken.isEmpty || providerName.isEmpty || isValidating)
                }
            }
            .navigationTitle("Add Cloud Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "Failed to connect provider")
            }
        }
    }
    
    private func openReferralLink() {
        if let url = URL(string: selectedProvider.referralLink) {
            UIApplication.shared.open(url)
        }
    }
    
    private func validateAndSave() {
        isValidating = true
        
        Task {
            do {
                // Create appropriate service
                let service: CloudProviderProtocol = selectedProvider == .digitalOcean ?
                    DigitalOceanService(apiToken: apiToken) :
                    HetznerCloudService(apiToken: apiToken)
                
                // Validate token
                let isValid = try await service.validateToken()
                
                if isValid {
                    // Create provider
                    let provider = ServerProvider(
                        providerType: selectedProvider.rawValue,
                        name: providerName.isEmpty ? selectedProvider.displayName : providerName
                    )
                    
                    // Store token in keychain
                    try KeychainManager.shared.storeProviderToken(apiToken, for: provider)
                    
                    // Save provider to database
                    modelContext.insert(provider)
                    try modelContext.save()
                    
                    await MainActor.run {
                        dismiss()
                        onProviderAdded?()
                    }
                } else {
                    await MainActor.run {
                        errorMessage = "Invalid API token"
                        showError = true
                        isValidating = false
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                    isValidating = false
                }
            }
        }
    }
}

// MARK: - Edit Cloud Provider View

struct EditCloudProviderView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    let provider: ServerProvider
    
    @State private var providerName: String = ""
    @State private var apiToken: String = ""
    @State private var showUpdateToken = false
    @State private var isValidating = false
    @State private var errorMessage: String?
    @State private var showError = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Provider Details") {
                    HStack {
                        ProviderIcon(
                            providerType: provider.providerType,
                            size: 24,
                            color: provider.providerType == "digitalocean" ? .blue : .orange
                        )
                        .frame(width: 30)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(provider.providerType == "digitalocean" ? "DigitalOcean" : "Hetzner Cloud")
                                .font(.headline)
                        }
                        
                        Spacer()
                        
                        // Use same pill style as CloudInitStatusBadge
                        Text("Connected")
                            .font(.caption2)
                            .foregroundColor(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.15))
                            .cornerRadius(4)
                    }
                }
                
                Section("Configuration") {
                    TextField("Display Name", text: $providerName)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    
                    HStack {
                        Text("API Token")
                        Spacer()
                        Button(showUpdateToken ? "Cancel" : "Update") {
                            showUpdateToken.toggle()
                            if !showUpdateToken {
                                apiToken = ""
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                    
                    if showUpdateToken {
                        SecureField("New API Token", text: $apiToken)
                            .font(.system(.body, design: .monospaced))
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                        
                        Button(action: validateAndUpdateToken) {
                            if isValidating {
                                HStack {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                        .scaleEffect(0.8)
                                    Text("Validating...")
                                }
                            } else {
                                Text("Validate & Update Token")
                            }
                        }
                        .disabled(apiToken.isEmpty || isValidating)
                    }
                }
            }
            .navigationTitle("Edit Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveChanges()
                    }
                    .disabled(providerName.isEmpty)
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "An error occurred")
            }
            .onAppear {
                providerName = provider.name
            }
        }
    }
    
    private func validateAndUpdateToken() {
        isValidating = true
        
        Task {
            do {
                // Create service to validate token
                let service: CloudProviderProtocol = provider.providerType == "digitalocean" ?
                    DigitalOceanService(apiToken: apiToken) :
                    HetznerCloudService(apiToken: apiToken)
                
                let isValid = try await service.validateToken()
                
                await MainActor.run {
                    if isValid {
                        // Update token in keychain
                        do {
                            try KeychainManager.shared.storeProviderToken(apiToken, for: provider)
                            showUpdateToken = false
                            apiToken = ""
                            
                            // Show success feedback
                            errorMessage = "API token updated successfully"
                            showError = true
                        } catch {
                            errorMessage = "Failed to update token: \(error.localizedDescription)"
                            showError = true
                        }
                    } else {
                        errorMessage = "Invalid API token"
                        showError = true
                    }
                    isValidating = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to validate token: \(error.localizedDescription)"
                    showError = true
                    isValidating = false
                }
            }
        }
    }
    
    private func saveChanges() {
        // Update provider name
        provider.name = providerName
        
        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = "Failed to save changes: \(error.localizedDescription)"
            showError = true
        }
    }
}

#Preview {
    CloudProvidersView()
        .modelContainer(for: [ServerProvider.self], inMemory: true)
}