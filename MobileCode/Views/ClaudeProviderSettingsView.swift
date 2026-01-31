//
//  ClaudeProviderSettingsView.swift
//  CodeAgentsMobile
//

import SwiftUI
import SwiftData

@MainActor
struct ClaudeProviderSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var servers: [Server]

    @State private var selectedProvider: ClaudeModelProvider
    @State private var selectedAuthMethod: ClaudeAuthMethod
    @State private var credentialInput = ""

    @State private var showError = false
    @State private var errorMessage: String?

    init() {
        let configuration = ClaudeProviderConfigurationStore.load()
        _selectedProvider = State(initialValue: configuration.selectedProvider)
        _selectedAuthMethod = State(initialValue: ClaudeCodeService.shared.getCurrentAuthMethod())
    }

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(selectableProviders) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
            }

            if selectedProvider == .anthropic {
                Section("Authentication") {
                    Picker("Authentication Method", selection: $selectedAuthMethod) {
                        Text("API Key").tag(ClaudeAuthMethod.apiKey)
                        Text("Authentication Token").tag(ClaudeAuthMethod.token)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
            }

            Section("Credentials") {
                SecureField(credentialPrompt, text: $credentialInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Text(credentialHelp)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Text("Endpoint, timeouts, and model defaults are preconfigured for each provider.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Claude Provider")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveAndSync()
                }
            }
        }
        .onAppear {
            loadCredential()
        }
        .onChange(of: selectedProvider) { oldValue, newValue in
            if oldValue == .anthropic, newValue != .anthropic {
                selectedAuthMethod = .apiKey
            }
            loadCredential()
        }
        .onChange(of: selectedAuthMethod) { _, _ in
            if selectedProvider == .anthropic {
                ClaudeCodeService.shared.setAuthMethod(selectedAuthMethod)
                loadCredential()
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "Something went wrong.")
        }
    }

    private var credentialPrompt: String {
        if selectedProvider == .anthropic {
            switch selectedAuthMethod {
            case .apiKey:
                return "Anthropic API Key"
            case .token:
                return "Claude Code Auth Token"
            }
        }
        return "\(selectedProvider.displayName) API Key"
    }

    private var credentialHelp: String {
        if selectedProvider == .anthropic {
            switch selectedAuthMethod {
            case .apiKey:
                return "Stored securely in the device keychain and synced to all servers running the proxy."
            case .token:
                return "Generate a token on your server with `claude setup-token`. Stored securely in the device keychain."
            }
        }
        return "Stored securely in the device keychain and synced to all servers running the proxy."
    }

    private func loadCredential() {
        do {
            if selectedProvider == .anthropic {
                switch selectedAuthMethod {
                case .apiKey:
                    credentialInput = try KeychainManager.shared.retrieveAPIKey(provider: .anthropic)
                case .token:
                    credentialInput = try KeychainManager.shared.retrieveAuthToken()
                }
            } else {
                credentialInput = try KeychainManager.shared.retrieveAPIKey(provider: selectedProvider)
            }
        } catch {
            credentialInput = ""
        }
    }

    private func saveAndSync() {
        var updated = ClaudeProviderConfiguration.defaults()
        updated.selectedProvider = selectedProvider
        ClaudeProviderConfigurationStore.save(updated)

        do {
            let trimmed = credentialInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if selectedProvider == .anthropic {
                switch selectedAuthMethod {
                case .apiKey:
                    if !trimmed.isEmpty {
                        try KeychainManager.shared.storeAPIKey(trimmed, provider: .anthropic)
                    }
                case .token:
                    if !trimmed.isEmpty {
                        try KeychainManager.shared.storeAuthToken(trimmed)
                    }
                }
            } else if !trimmed.isEmpty {
                try KeychainManager.shared.storeAPIKey(trimmed, provider: selectedProvider)
            }
        } catch {
            errorMessage = "Failed to save credentials: \(error.localizedDescription)"
            showError = true
            return
        }

        let serversToUpdate = servers
        if !serversToUpdate.isEmpty {
            Task {
                await ProxyInstallerService.shared.syncProxyConfiguration(on: serversToUpdate)
            }
        }

        dismiss()
    }

    private var selectableProviders: [ClaudeModelProvider] {
        [
            .anthropic,
            .zAI,
            .miniMax,
            .moonshot
        ]
    }
}

#Preview {
    NavigationStack {
        ClaudeProviderSettingsView()
    }
    .modelContainer(for: [Server.self], inMemory: true)
}
