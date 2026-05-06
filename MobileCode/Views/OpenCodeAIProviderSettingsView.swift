//
//  OpenCodeAIProviderSettingsView.swift
//  CodeAgentsMobile
//
//  Purpose: Global and per-server OpenCode AI provider credentials/settings
//

import SwiftUI
import SwiftData

struct OpenCodeAIProviderSettingsView: View {
    let server: Server?

    @Query(sort: \Server.name) private var servers: [Server]
    @StateObject private var providerService = OpenCodeProviderService.shared

    @State private var useGlobalDefaults = true
    @State private var profile = OpenCodeAIProviderProfile.defaults()
    @State private var apiKey = ""
    @State private var customProviderEnabled = false
    @State private var isSavingLocal = false
    @State private var isApplying = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showError = false

    private let settingsStore = OpenCodeAIProviderSettingsStore()

    init(server: Server? = nil) {
        self.server = server
    }

    var body: some View {
        Form {
            if let server {
                Section("Scope") {
                    Toggle("Use Global Defaults", isOn: $useGlobalDefaults)
                        .accessibilityIdentifier("opencode-ai-use-global-toggle")

                    LabeledContent("Server", value: server.name)

                    if useGlobalDefaults {
                        Text("This server uses the global OpenCode provider profile. Applying will sync those global settings to this server.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            providerSection
            modelSection
            customProviderSection
            saveSection
            applySection

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(server == nil ? "OpenCode AI" : "Server AI")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadSettings()
        }
        .onChange(of: useGlobalDefaults) { _, newValue in
            guard let server else { return }
            if newValue {
                profile = settingsStore.globalProfile()
                customProviderEnabled = profile.isCustomProvider
                apiKey = ""
            } else {
                let override = settingsStore.serverOverride(for: server.id)
                profile = override.profile.normalizedForStorage()
                customProviderEnabled = profile.isCustomProvider
                apiKey = ""
            }
        }
        .alert("OpenCode AI Provider", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "Something went wrong.")
        }
    }

    private var editsDisabled: Bool {
        server != nil && useGlobalDefaults
    }

    @ViewBuilder
    private var providerSection: some View {
        Section("Provider") {
            Picker("Authentication", selection: authModeBinding) {
                ForEach(OpenCodeProviderAuthMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .disabled(editsDisabled)
            .accessibilityIdentifier("opencode-ai-auth-mode-picker")

            TextField("Provider ID", text: $profile.providerID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(editsDisabled || profile.authMode == .openAIChatGPT)
                .accessibilityIdentifier("opencode-ai-provider-id-field")

            TextField("Display Name", text: $profile.providerName)
                .disabled(editsDisabled)
                .accessibilityIdentifier("opencode-ai-provider-name-field")

            if profile.authMode.requiresAPIKey {
                SecureField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(editsDisabled)
                    .accessibilityIdentifier("opencode-ai-api-key-field")

                Text("Keys are stored only in the device Keychain. Leave blank to keep the existing local key.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Use this after OpenCode has been connected on the server with /connect > OpenAI > ChatGPT Plus/Pro. MobileCode will sync model settings without storing an API key.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        Section("Models") {
            TextField("Default Model (provider/model)", text: $profile.modelID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(editsDisabled)
                .accessibilityIdentifier("opencode-ai-model-id-field")

            TextField("Small Model (optional)", text: $profile.smallModelID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(editsDisabled)
                .accessibilityIdentifier("opencode-ai-small-model-id-field")

            Text("Use OpenCode's provider/model id format, for example openai/gpt-5.2 or minimax/MiniMax-M2.7.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var customProviderSection: some View {
        Section {
            Toggle("OpenAI-Compatible Endpoint", isOn: customProviderBinding)
                .disabled(editsDisabled)
                .accessibilityIdentifier("opencode-ai-custom-provider-toggle")

            if customProviderEnabled {
                Picker("API Style", selection: npmDriverBinding) {
                    ForEach(OpenCodeProviderNPMDriver.allCases) { driver in
                        Text(driver.displayName).tag(driver)
                    }
                }
                .disabled(editsDisabled)

                TextField("Base URL", text: $profile.customBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .disabled(editsDisabled)
                    .accessibilityIdentifier("opencode-ai-custom-base-url-field")

                TextField("Model ID", text: $profile.customModelID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(editsDisabled)
                    .accessibilityIdentifier("opencode-ai-custom-model-id-field")

                TextField("Model Name", text: $profile.customModelName)
                    .disabled(editsDisabled)
                    .accessibilityIdentifier("opencode-ai-custom-model-name-field")
            }
        } header: {
            Text("Custom Provider")
        } footer: {
            Text("Custom providers are written to the server's global OpenCode config. API keys still go through OpenCode auth instead of being embedded in opencode.json.")
        }
    }

    @ViewBuilder
    private var saveSection: some View {
        Section {
            Button {
                Task { await saveLocalSettings() }
            } label: {
                if isSavingLocal {
                    ProgressView()
                } else {
                    Label("Save Locally", systemImage: "key")
                }
            }
            .disabled(isSavingLocal || !profile.isReadyToSave)
            .accessibilityIdentifier("opencode-ai-save-local-button")
        } footer: {
            Text(server == nil ? "Saved as the global CodeAgents default for future OpenCode servers." : "Saved as this server's local override. It is not applied to the server until you sync.")
        }
    }

    @ViewBuilder
    private var applySection: some View {
        if let server {
            Section("Sync") {
                Button {
                    Task { await applySettings(to: server) }
                } label: {
                    if isApplying {
                        ProgressView()
                    } else {
                        Label("Apply to This Server", systemImage: "arrow.up.doc")
                    }
                }
                .disabled(isApplying || !profile.isReadyToSave)
                .accessibilityIdentifier("opencode-ai-apply-server-button")
            }
        } else {
            Section("Sync to Servers") {
                Button {
                    Task { await applyGlobalSettingsToAllServers() }
                } label: {
                    if isApplying {
                        ProgressView()
                    } else {
                        Label("Apply to All Servers", systemImage: "arrow.up.doc.on.clipboard")
                    }
                }
                .disabled(isApplying || servers.isEmpty || !profile.isReadyToSave)
                .accessibilityIdentifier("opencode-ai-apply-all-servers-button")

                ForEach(servers) { server in
                    Button {
                        Task { await applySettings(to: server) }
                    } label: {
                        HStack {
                            Text(server.name)
                            Spacer()
                            Text("\(server.username)@\(server.host)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(isApplying || !profile.isReadyToSave)
                }
            }
        }
    }

    private var authModeBinding: Binding<OpenCodeProviderAuthMode> {
        Binding(
            get: { profile.authMode },
            set: { newValue in
                profile.authMode = newValue
                if newValue == .openAIChatGPT {
                    profile.providerID = "openai"
                    profile.providerName = "OpenAI"
                    apiKey = ""
                }
            }
        )
    }

    private var npmDriverBinding: Binding<OpenCodeProviderNPMDriver> {
        Binding(
            get: { profile.npmDriver },
            set: { profile.npmDriver = $0 }
        )
    }

    private var customProviderBinding: Binding<Bool> {
        Binding(
            get: { customProviderEnabled },
            set: { newValue in
                customProviderEnabled = newValue
                if !newValue {
                    profile.customBaseURL = ""
                    profile.customModelID = ""
                    profile.customModelName = ""
                }
            }
        )
    }

    private func loadSettings() {
        if let server {
            let override = settingsStore.serverOverride(for: server.id)
            useGlobalDefaults = override.usesGlobalDefaults
            profile = override.usesGlobalDefaults ? settingsStore.globalProfile() : override.profile.normalizedForStorage()
        } else {
            profile = settingsStore.globalProfile()
            useGlobalDefaults = false
        }
        customProviderEnabled = profile.isCustomProvider
        apiKey = ""
    }

    @MainActor
    private func saveLocalSettings() async {
        isSavingLocal = true
        defer { isSavingLocal = false }

        do {
            try persistLocalSettings()
            statusMessage = "Saved locally."
        } catch {
            present(error)
        }
    }

    private func persistLocalSettings() throws {
        let normalized = profile.normalizedForStorage()
        guard normalized.isReadyToSave else {
            throw OpenCodeProviderServiceError.invalidInput
        }

        if let server {
            let override = OpenCodeServerAIProviderOverride(
                usesGlobalDefaults: useGlobalDefaults,
                profile: normalized
            )
            try settingsStore.saveServerOverride(override, for: server.id)
            if !useGlobalDefaults, normalized.authMode.requiresAPIKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try KeychainManager.shared.storeOpenCodeAPIKey(apiKey, providerID: normalized.providerID, serverID: server.id)
                apiKey = ""
            }
        } else {
            try settingsStore.saveGlobalProfile(normalized)
            if normalized.authMode.requiresAPIKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try KeychainManager.shared.storeOpenCodeAPIKey(apiKey, providerID: normalized.providerID)
                apiKey = ""
            }
        }
    }

    @MainActor
    private func applySettings(to targetServer: Server) async {
        isApplying = true
        defer { isApplying = false }

        do {
            try persistLocalSettings()

            let profileToApply: OpenCodeAIProviderProfile
            let credentialScope: OpenCodeAIProviderCredentialScope
            if let sourceServer = server {
                profileToApply = settingsStore.effectiveProfile(for: sourceServer.id)
                credentialScope = useGlobalDefaults ? .global : .server(sourceServer.id)
            } else {
                profileToApply = settingsStore.globalProfile()
                credentialScope = .global
            }

            try await providerService.applyAIProviderProfile(
                profileToApply,
                credentialScope: credentialScope,
                to: targetServer
            )
            statusMessage = "Applied to \(targetServer.name)."
        } catch {
            present(error)
        }
    }

    @MainActor
    private func applyGlobalSettingsToAllServers() async {
        isApplying = true
        defer { isApplying = false }

        do {
            try persistLocalSettings()
            let globalProfile = settingsStore.globalProfile()
            for targetServer in servers {
                try await providerService.applyAIProviderProfile(
                    globalProfile,
                    credentialScope: .global,
                    to: targetServer
                )
            }
            statusMessage = "Applied to \(servers.count) server\(servers.count == 1 ? "" : "s")."
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }
}

#Preview {
    NavigationStack {
        OpenCodeAIProviderSettingsView()
    }
    .modelContainer(for: [Server.self], inMemory: true)
}
