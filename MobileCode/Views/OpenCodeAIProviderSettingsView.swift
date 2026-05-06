//
//  OpenCodeAIProviderSettingsView.swift
//  CodeAgentsMobile
//
//  Purpose: OpenCode-style provider connection and model selection flow
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
    @State private var showProviderPicker = false
    @State private var showModelPicker = false
    @State private var showAdvancedProvider = false
    @State private var showAdvancedModels = false
    @State private var confirmApplyAll = false
    @State private var providerStatus: OpenCodeProviderStatus?
    @State private var statusSourceName: String?
    @State private var hasStoredAPIKey = false
    @State private var isSavingLocal = false
    @State private var isApplying = false
    @State private var isRefreshingStatus = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showError = false

    private let settingsStore = OpenCodeAIProviderSettingsStore()

    init(server: Server? = nil) {
        self.server = server
    }

    var body: some View {
        Form {
            scopeSection
            connectProviderSection
            credentialSection
            modelSection
            syncSection
            statusSection
        }
        .navigationTitle(server == nil ? "OpenCode AI" : "Server AI")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadSettings()
            Task { await refreshProviderStatusIfPossible() }
        }
        .onChange(of: useGlobalDefaults) { _, newValue in
            loadServerScope(useGlobalDefaults: newValue)
        }
        .sheet(isPresented: $showProviderPicker) {
            OpenCodeProviderPickerSheet(
                choices: providerChoices,
                selectedProviderID: profile.normalizedProviderID,
                searchTitle: "Choose Provider"
            ) { choice in
                selectProvider(choice)
                showProviderPicker = false
            }
        }
        .sheet(isPresented: $showModelPicker) {
            OpenCodeModelPickerSheet(
                choices: selectedProviderModelChoices,
                selectedModelID: profile.modelID
            ) { choice in
                profile.modelID = choice.id
                if profile.smallModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    profile.smallModelID = OpenCodeProviderConnectionDefaults.suggestedSmallModelID(
                        providerID: choice.providerID,
                        status: providerStatus
                    ) ?? ""
                }
                showModelPicker = false
            }
        }
        .confirmationDialog(
            "Sync OpenCode AI settings to every server?",
            isPresented: $confirmApplyAll,
            titleVisibility: .visible
        ) {
            Button("Sync \(servers.count) Server\(servers.count == 1 ? "" : "s")") {
                Task { await applyGlobalSettingsToAllServers() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This updates the provider and model selection on each server. API keys stay in this device's Keychain and are sent to OpenCode only during sync.")
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
    private var scopeSection: some View {
        if let server {
            Section {
                Toggle("Use Global Defaults", isOn: $useGlobalDefaults)
                    .accessibilityIdentifier("opencode-ai-use-global-toggle")

                LabeledContent("Server", value: server.name)

                if useGlobalDefaults {
                    Label("This server follows the global CodeAgents provider setup.", systemImage: "arrow.triangle.branch")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Scope")
            }
        }
    }

    private var connectProviderSection: some View {
        Section {
            Button {
                showProviderPicker = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selectedProviderSymbol)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedProviderName)
                            .font(.body)
                            .foregroundColor(.primary)
                        Text(selectedProviderSubtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
            }
            .disabled(editsDisabled)
            .accessibilityIdentifier("opencode-ai-provider-picker-button")

            if customProviderEnabled {
                customProviderFields
            }
        } header: {
            stepHeader(number: 1, title: "Connect Provider", isComplete: providerStepComplete)
        } footer: {
            Text("Matches OpenCode's /connect flow: pick a listed provider, or choose Other for an OpenAI-compatible endpoint.")
        }
    }

    @ViewBuilder
    private var customProviderFields: some View {
        TextField("Provider ID", text: $profile.providerID)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(editsDisabled)
            .accessibilityIdentifier("opencode-ai-provider-id-field")

        TextField("Display Name", text: $profile.providerName)
            .disabled(editsDisabled)
            .accessibilityIdentifier("opencode-ai-provider-name-field")

        TextField("Base URL", text: $profile.customBaseURL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .disabled(editsDisabled)
            .accessibilityIdentifier("opencode-ai-custom-base-url-field")

        DisclosureGroup("Advanced", isExpanded: $showAdvancedProvider) {
            Picker("API Style", selection: npmDriverBinding) {
                ForEach(OpenCodeProviderNPMDriver.allCases) { driver in
                    Text(driver.displayName).tag(driver)
                }
            }
            .disabled(editsDisabled)
        }
    }

    private var credentialSection: some View {
        Section {
            if supportsChatGPTAuth {
                Picker("Sign in with", selection: authModeBinding) {
                    Text("API Key").tag(OpenCodeProviderAuthMode.apiKey)
                    Text("ChatGPT Plus/Pro").tag(OpenCodeProviderAuthMode.openAIChatGPT)
                }
                .pickerStyle(.segmented)
                .disabled(editsDisabled)
                .accessibilityIdentifier("opencode-ai-auth-mode-picker")
            } else {
                LabeledContent("Sign in with") {
                    Text("API Key")
                        .foregroundColor(.secondary)
                }
            }

            if profile.authMode.requiresAPIKey {
                if hasStoredAPIKey {
                    Label("API key saved on this device", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.footnote)
                }

                SecureField(hasStoredAPIKey ? "Replace API Key" : "API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(editsDisabled)
                    .accessibilityIdentifier("opencode-ai-api-key-field")
            } else {
                chatGPTConnectionView
            }
        } header: {
            stepHeader(number: 2, title: "Authenticate", isComplete: credentialStepComplete)
        } footer: {
            Text(credentialFooterText)
        }
    }

    @ViewBuilder
    private var chatGPTConnectionView: some View {
        if providerIsConnected {
            Label("OpenAI is connected on \(statusSourceName ?? "the server")", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.footnote)
        } else {
            Label("Connect OpenAI in OpenCode, then return here", systemImage: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.secondary)
                .font(.footnote)

            Text("Run /connect, choose OpenAI, then select ChatGPT Plus/Pro.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var modelSection: some View {
        Section {
            if customProviderEnabled {
                TextField("Model ID", text: $profile.customModelID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(editsDisabled)
                    .accessibilityIdentifier("opencode-ai-custom-model-id-field")

                TextField("Model Name", text: $profile.customModelName)
                    .disabled(editsDisabled)
                    .accessibilityIdentifier("opencode-ai-custom-model-name-field")

                LabeledContent("Default Model") {
                    Text(profile.resolvedModelID ?? "Add model ID")
                        .foregroundColor(.secondary)
                }
            } else if selectedProviderModelChoices.isEmpty {
                TextField("Model ID", text: $profile.modelID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(editsDisabled)
                    .accessibilityIdentifier("opencode-ai-model-id-field")
            } else {
                Button {
                    showModelPicker = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedModelTitle)
                                .foregroundColor(.primary)
                            Text("Choose from \(selectedProviderModelChoices.count) models")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(editsDisabled)
                .accessibilityIdentifier("opencode-ai-model-picker-button")
            }

            DisclosureGroup("Advanced", isExpanded: $showAdvancedModels) {
                TextField("Small Model", text: $profile.smallModelID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(editsDisabled)
                    .accessibilityIdentifier("opencode-ai-small-model-id-field")
            }
        } header: {
            stepHeader(number: 3, title: "Select Model", isComplete: modelStepComplete)
        } footer: {
            Text("This follows OpenCode's /models step. The selected value is saved as provider/model in OpenCode config.")
        }
    }

    private var syncSection: some View {
        Section {
            Button {
                Task { await saveLocalSettings() }
            } label: {
                savingLabel(isWorking: isSavingLocal, title: "Save on This Device", systemImage: "key")
            }
            .disabled(isSavingLocal || !canSave)
            .accessibilityIdentifier("opencode-ai-save-local-button")

            if let server {
                Button {
                    Task { await applySettings(to: server) }
                } label: {
                    savingLabel(isWorking: isApplying, title: "Sync to This Server", systemImage: "arrow.up.circle")
                }
                .disabled(isApplying || !canSync)
                .accessibilityIdentifier("opencode-ai-apply-server-button")
            } else {
                Button {
                    confirmApplyAll = true
                } label: {
                    savingLabel(isWorking: isApplying, title: "Sync to All Servers", systemImage: "arrow.up.circle")
                }
                .disabled(isApplying || servers.isEmpty || !canSync)
                .accessibilityIdentifier("opencode-ai-apply-all-servers-button")
            }
        } header: {
            stepHeader(number: 4, title: "Sync", isComplete: false)
        } footer: {
            Text("Saving keeps this setup in CodeAgents. Syncing updates OpenCode on the server.")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if isRefreshingStatus || providerStatus != nil || statusMessage != nil {
            Section {
                if isRefreshingStatus {
                    HStack {
                        ProgressView()
                        Text("Checking OpenCode providers...")
                            .foregroundColor(.secondary)
                    }
                }

                if let statusSourceName, let providerStatus {
                    LabeledContent("Provider list") {
                        Text("\(providerStatus.providers.count) from \(statusSourceName)")
                            .foregroundColor(.secondary)
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundColor(.secondary)
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
                    customProviderEnabled = false
                    apiKey = ""
                }
                refreshStoredCredentialState()
            }
        )
    }

    private var npmDriverBinding: Binding<OpenCodeProviderNPMDriver> {
        Binding(
            get: { profile.npmDriver },
            set: { profile.npmDriver = $0 }
        )
    }

    private var providerChoices: [OpenCodeProviderChoice] {
        var seen = Set<String>()
        var choices: [OpenCodeProviderChoice] = []

        func append(_ choice: OpenCodeProviderChoice) {
            let normalizedID = choice.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let key = choice.isCustom ? "__custom" : normalizedID
            guard !key.isEmpty, !seen.contains(key) else { return }
            seen.insert(key)
            choices.append(choice)
        }

        for provider in providerStatus?.providers ?? [] {
            append(OpenCodeProviderChoice(
                id: provider.id,
                name: provider.name,
                subtitle: provider.models.isEmpty ? "Provider from OpenCode" : "\(provider.models.count) models available",
                systemImage: OpenCodeProviderPreset.symbol(for: provider.id),
                isCustom: false,
                isConnected: providerStatus?.connectedProviderIDs.contains(where: { $0.caseInsensitiveCompare(provider.id) == .orderedSame }) == true,
                supportsChatGPT: provider.id.caseInsensitiveCompare("openai") == .orderedSame
            ))
        }

        for preset in OpenCodeProviderPreset.preferred {
            append(OpenCodeProviderChoice(
                id: preset.id,
                name: preset.name,
                subtitle: preset.subtitle,
                systemImage: preset.systemImage,
                isCustom: false,
                isConnected: providerStatus?.connectedProviderIDs.contains(where: { $0.caseInsensitiveCompare(preset.id) == .orderedSame }) == true,
                supportsChatGPT: preset.supportsChatGPT
            ))
        }

        append(OpenCodeProviderChoice(
            id: "other",
            name: "Other",
            subtitle: "OpenAI-compatible endpoint",
            systemImage: "plus.circle",
            isCustom: true,
            isConnected: false,
            supportsChatGPT: false
        ))

        return choices
    }

    private var selectedProviderModelChoices: [OpenCodeModelChoice] {
        guard !profile.normalizedProviderID.isEmpty else { return [] }
        return providerStatus?.modelChoices.filter {
            $0.providerID.caseInsensitiveCompare(profile.normalizedProviderID) == .orderedSame
        } ?? []
    }

    private var selectedProviderName: String {
        if customProviderEnabled {
            let name = profile.providerName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Other" : name
        }
        return OpenCodeProviderPreset.name(for: profile.normalizedProviderID) ?? profile.trimmedProviderName
    }

    private var selectedProviderSubtitle: String {
        if customProviderEnabled {
            return "OpenAI-compatible endpoint"
        }
        if providerIsConnected {
            return "Connected in OpenCode"
        }
        return "Provider from OpenCode"
    }

    private var selectedProviderSymbol: String {
        customProviderEnabled ? "plus.circle" : OpenCodeProviderPreset.symbol(for: profile.normalizedProviderID)
    }

    private var selectedModelTitle: String {
        guard let modelID = profile.resolvedModelID, !modelID.isEmpty else {
            return "Choose Model"
        }
        return selectedProviderModelChoices.first(where: { $0.id == modelID })?.modelName ?? modelID
    }

    private var supportsChatGPTAuth: Bool {
        profile.normalizedProviderID == "openai" && !customProviderEnabled
    }

    private var providerIsConnected: Bool {
        providerStatus?.connectedProviderIDs.contains {
            $0.caseInsensitiveCompare(profile.normalizedProviderID) == .orderedSame
        } == true
    }

    private var providerStepComplete: Bool {
        guard !profile.normalizedProviderID.isEmpty else { return false }
        if customProviderEnabled {
            return !profile.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private var credentialStepComplete: Bool {
        if profile.authMode.requiresAPIKey {
            return hasStoredAPIKey || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return providerIsConnected
    }

    private var modelStepComplete: Bool {
        profile.resolvedModelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var canSave: Bool {
        profile.isReadyToSave
    }

    private var canSync: Bool {
        guard profile.isReadyToSave else { return false }
        if profile.authMode.requiresAPIKey {
            return hasStoredAPIKey || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private var credentialFooterText: String {
        if profile.authMode.requiresAPIKey {
            return "Like /connect, this stores a credential first. CodeAgents keeps the key in Keychain and sends it to OpenCode only when you sync."
        }
        return "ChatGPT Plus/Pro uses OpenCode's own OpenAI connection on the server. No API key is stored in CodeAgents."
    }

    private func stepHeader(number: Int, title: String, isComplete: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundStyle(isComplete ? .green : .secondary)
            Text(title)
        }
    }

    private func savingLabel(isWorking: Bool, title: String, systemImage: String) -> some View {
        HStack {
            if isWorking {
                ProgressView()
            } else {
                Label(title, systemImage: systemImage)
            }
        }
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
        showAdvancedProvider = profile.isCustomProvider
        refreshStoredCredentialState()
    }

    private func loadServerScope(useGlobalDefaults: Bool) {
        guard let server else { return }
        if useGlobalDefaults {
            profile = settingsStore.globalProfile()
        } else {
            profile = settingsStore.serverOverride(for: server.id).profile.normalizedForStorage()
        }
        customProviderEnabled = profile.isCustomProvider
        apiKey = ""
        showAdvancedProvider = profile.isCustomProvider
        refreshStoredCredentialState()
    }

    private func selectProvider(_ choice: OpenCodeProviderChoice) {
        if choice.isCustom {
            customProviderEnabled = true
            profile.authMode = .apiKey
            if profile.providerID == "openai" || profile.providerID.isEmpty {
                profile.providerID = ""
            }
            if profile.providerName == "OpenAI" {
                profile.providerName = ""
            }
            profile.modelID = ""
            showAdvancedProvider = true
        } else {
            customProviderEnabled = false
            profile.providerID = choice.id
            profile.providerName = choice.name
            profile.customBaseURL = ""
            profile.customModelID = ""
            profile.customModelName = ""
            if !choice.supportsChatGPT && profile.authMode == .openAIChatGPT {
                profile.authMode = .apiKey
            }
            if profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.modelID = OpenCodeProviderConnectionDefaults.suggestedModelID(
                    providerID: choice.id,
                    status: providerStatus
                ) ?? ""
            }
        }
        apiKey = ""
        refreshStoredCredentialState()
    }

    @MainActor
    private func refreshProviderStatusIfPossible() async {
        let targetServer = server ?? servers.first
        guard let targetServer else { return }

        isRefreshingStatus = true
        defer { isRefreshingStatus = false }

        do {
            providerStatus = try await providerService.status(for: targetServer)
            statusSourceName = targetServer.name
        } catch {
            statusMessage = "Provider list unavailable. You can still connect a provider manually."
        }
    }

    @MainActor
    private func saveLocalSettings() async {
        isSavingLocal = true
        defer { isSavingLocal = false }

        do {
            try persistLocalSettings()
            statusMessage = "Saved on this device."
        } catch {
            present(error)
        }
    }

    private func persistLocalSettings() throws {
        if customProviderEnabled {
            profile.modelID = ""
        }
        let normalized = profile.normalizedForStorage()
        guard normalized.isReadyToSave else {
            throw OpenCodeProviderServiceError.invalidInput
        }

        if let server {
            try settingsStore.saveServerOverride(
                OpenCodeServerAIProviderOverride(
                    usesGlobalDefaults: useGlobalDefaults,
                    profile: normalized
                ),
                for: server.id
            )
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
        refreshStoredCredentialState()
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
            statusMessage = "Synced to \(targetServer.name)."
            await refreshProviderStatusIfPossible()
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
            statusMessage = "Synced to \(servers.count) server\(servers.count == 1 ? "" : "s")."
            await refreshProviderStatusIfPossible()
        } catch {
            present(error)
        }
    }

    private func refreshStoredCredentialState() {
        guard profile.authMode.requiresAPIKey else {
            hasStoredAPIKey = false
            return
        }

        if let server, !useGlobalDefaults {
            hasStoredAPIKey = KeychainManager.shared.hasOpenCodeAPIKey(providerID: profile.normalizedProviderID, serverID: server.id)
        } else {
            hasStoredAPIKey = KeychainManager.shared.hasOpenCodeAPIKey(providerID: profile.normalizedProviderID)
        }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }
}

private struct OpenCodeProviderChoice: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let systemImage: String
    let isCustom: Bool
    let isConnected: Bool
    let supportsChatGPT: Bool
}

private enum OpenCodeProviderPreset {
    static let preferred: [OpenCodeProviderChoice] = [
        OpenCodeProviderChoice(
            id: "opencode",
            name: "OpenCode Zen",
            subtitle: "Recommended tested coding models",
            systemImage: "checkmark.seal",
            isCustom: false,
            isConnected: false,
            supportsChatGPT: false
        ),
        OpenCodeProviderChoice(
            id: "openai",
            name: "OpenAI",
            subtitle: "GPT and ChatGPT Plus/Pro",
            systemImage: "sparkles",
            isCustom: false,
            isConnected: false,
            supportsChatGPT: true
        ),
        OpenCodeProviderChoice(
            id: "anthropic",
            name: "Anthropic",
            subtitle: "Claude models",
            systemImage: "brain.head.profile",
            isCustom: false,
            isConnected: false,
            supportsChatGPT: false
        ),
        OpenCodeProviderChoice(
            id: "openrouter",
            name: "OpenRouter",
            subtitle: "Many providers through one API",
            systemImage: "point.3.connected.trianglepath.dotted",
            isCustom: false,
            isConnected: false,
            supportsChatGPT: false
        ),
        OpenCodeProviderChoice(
            id: "google",
            name: "Google",
            subtitle: "Gemini models",
            systemImage: "globe",
            isCustom: false,
            isConnected: false,
            supportsChatGPT: false
        ),
        OpenCodeProviderChoice(
            id: "minimax",
            name: "MiniMax",
            subtitle: "M2 coding models",
            systemImage: "bolt.horizontal.circle",
            isCustom: false,
            isConnected: false,
            supportsChatGPT: false
        ),
        OpenCodeProviderChoice(
            id: "xai",
            name: "xAI",
            subtitle: "Grok models",
            systemImage: "xmark.circle",
            isCustom: false,
            isConnected: false,
            supportsChatGPT: false
        )
    ]

    static func name(for providerID: String) -> String? {
        preferred.first { $0.id.caseInsensitiveCompare(providerID) == .orderedSame }?.name
    }

    static func symbol(for providerID: String) -> String {
        preferred.first { $0.id.caseInsensitiveCompare(providerID) == .orderedSame }?.systemImage ?? "cpu"
    }
}

private struct OpenCodeProviderPickerSheet: View {
    let choices: [OpenCodeProviderChoice]
    let selectedProviderID: String
    let searchTitle: String
    let onSelect: (OpenCodeProviderChoice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List(filteredChoices) { choice in
                Button {
                    onSelect(choice)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: choice.systemImage)
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(choice.name)
                                .foregroundColor(.primary)
                            Text(choice.subtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if choice.isConnected {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        } else if !choice.isCustom && choice.id.caseInsensitiveCompare(selectedProviderID) == .orderedSame {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .navigationTitle(searchTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search providers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var filteredChoices: [OpenCodeProviderChoice] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return choices }
        return choices.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
                || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }
}

private struct OpenCodeModelPickerSheet: View {
    let choices: [OpenCodeModelChoice]
    let selectedModelID: String
    let onSelect: (OpenCodeModelChoice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List(filteredChoices) { choice in
                Button {
                    onSelect(choice)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(choice.modelName)
                                .foregroundColor(.primary)
                            Text(choice.id)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if choice.id == selectedModelID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .navigationTitle("Choose Model")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search models")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var filteredChoices: [OpenCodeModelChoice] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return choices }
        return choices.filter {
            $0.modelName.localizedCaseInsensitiveContains(query)
                || $0.modelID.localizedCaseInsensitiveContains(query)
                || $0.providerName.localizedCaseInsensitiveContains(query)
        }
    }
}

#Preview {
    NavigationStack {
        OpenCodeAIProviderSettingsView()
    }
    .modelContainer(for: [Server.self], inMemory: true)
}
