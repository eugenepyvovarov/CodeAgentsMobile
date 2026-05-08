//
//  AgentRuntimeSettingsView.swift
//  CodeAgentsMobile
//
//  Purpose: Runtime and OpenCode provider settings
//

import SwiftUI

struct AgentRuntimeSettingsView: View {
    @StateObject private var projectContext = ProjectContext.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CodingAgentRuntimeSelectionStore.selectedRuntimeKey) private var selectedRuntimeRawValue = CodingAgentRuntimeSelectionStore.defaultRuntime.rawValue

    @StateObject private var providerService = OpenCodeProviderService.shared
    @State private var runtimeHealth: CodingAgentRuntimeHealth?
    @State private var providerStatus: OpenCodeProviderStatus?
    @State private var apiProviderID = "anthropic"
    @State private var apiKey = ""
    @State private var modelConfigScope: OpenCodeConfigurationScope = .global
    @State private var selectedModelID = ""
    @State private var selectedSmallModelID = ""
    @State private var customProviderID = ""
    @State private var customProviderName = ""
    @State private var customProviderBaseURL = ""
    @State private var customProviderModelID = ""
    @State private var customProviderModelName = ""
    @State private var customProviderAPIKey = ""
    @State private var isLoadingStatus = false
    @State private var isSavingAPIKey = false
    @State private var isSavingProviderConnection = false
    @State private var isSavingModelConfiguration = false
    @State private var isSavingCustomProvider = false
    @State private var providerStatusWarning: String?
    @State private var errorMessage: String?
    @State private var showError = false

    private let runtimeRegistry = CodingAgentRuntimeRegistry()
    private let runtimeSelectionStore = CodingAgentRuntimeSelectionStore()

    private var selectedRuntime: CodingAgentRuntimeKind {
        CodingAgentRuntimeKind(rawValue: selectedRuntimeRawValue) ?? CodingAgentRuntimeSelectionStore.defaultRuntime
    }

    private var effectiveRuntime: CodingAgentRuntimeKind {
        activeProject?.selectedAgentRuntime ?? selectedRuntime
    }

    private var activeProject: RemoteProject? {
        projectContext.activeProject
    }

    private var apiKeyProviderChoices: [OpenCodeAPIKeyProviderChoice] {
        providerStatus?.apiKeyProviderChoices ?? OpenCodeAPIKeyProviderChoice.preferred
    }

    private var selectedProviderModelChoices: [OpenCodeModelChoice] {
        guard let providerStatus else { return [] }
        return providerStatus.modelChoices.filter {
            $0.providerID.caseInsensitiveCompare(apiProviderID) == .orderedSame
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Runtime", selection: runtimeBinding) {
                    ForEach(CodingAgentRuntimeKind.allCases) { runtime in
                        Text(runtime.displayName).tag(runtime)
                    }
                }
                .accessibilityIdentifier("agent-runtime-picker")
                .accessibilityValue(runtimeOptionsAccessibilityValue)

                if let project = activeProject {
                    LabeledContent("Active Agent", value: project.displayTitle)
                    LabeledContent("Agent Runtime", value: project.selectedAgentRuntime.displayName)
                } else {
                    Text("Select an agent to check runtime health.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Runtime")
            } footer: {
                Text("New agents use OpenCode by default. Existing legacy agents stay on Claude Proxy until you switch them here.")
            }

            Section {
                NavigationLink {
                    AIProviderSettingsView(initialMode: .openCode)
                } label: {
                    Label("Global Provider & Models", systemImage: "sparkles")
                }
                .accessibilityIdentifier("agent-runtime-ai-providers-global-link")

                if let activeServer = projectContext.activeServer {
                    NavigationLink {
                        AIProviderSettingsView(initialMode: .openCode, server: activeServer)
                    } label: {
                        Label("This Server Override", systemImage: "server.rack")
                    }
                    .accessibilityIdentifier("agent-runtime-ai-providers-server-link")
                }
            } header: {
                Text("AI Provider Defaults")
            } footer: {
                Text("Store provider credentials on this device and sync the selected provider/model profile to each OpenCode server.")
            }

            if let activeProject {
                Section("Status") {
                    Button {
                        Task { await refreshStatus(for: activeProject) }
                    } label: {
                        if isLoadingStatus {
                            HStack {
                                ProgressView()
                                Text("Checking...")
                            }
                        } else {
                            Label("Check Runtime", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isLoadingStatus)
                    .accessibilityIdentifier("agent-runtime-check-button")

                    if let runtimeHealth {
                        LabeledContent("Health", value: healthText(runtimeHealth))
                        if let version = runtimeHealth.version {
                            LabeledContent("Version", value: version)
                        }
                        if let message = runtimeHealth.message {
                            Text(message)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if effectiveRuntime == .openCode {
                    openCodeProviderSections(project: activeProject)
                }
            }
        }
        .navigationTitle("Agent Runtime")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    dismiss()
                }
                .accessibilityIdentifier("agent-runtime-done-button")
            }
        }
        .task {
            applyUITestAIProviderAutofillIfNeeded()
            if let activeProject {
                await refreshStatus(for: activeProject)
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "Something went wrong.")
        }
    }

    @ViewBuilder
    private func openCodeProviderSections(project: RemoteProject) -> some View {
        Section("OpenCode Providers") {
            if let providerStatus {
                if providerStatus.connectedProviderIDs.isEmpty {
                    Text("No connected OpenCode providers reported.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    LabeledContent("Connected", value: providerStatus.connectedProviderIDs.joined(separator: ", "))
                }

                let visibleProviders = providerStatus.providers.prefix(8)
                ForEach(Array(visibleProviders), id: \.id) { provider in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(provider.name)
                            Spacer()
                            Text(provider.id)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if let model = providerStatus.defaultModels[provider.id] {
                            Text("Default model: \(model)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if let methods = providerStatus.authMethods[provider.id], !methods.isEmpty {
                            Text("Auth: \(methods.map(\.label).joined(separator: ", "))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if providerStatus.authMethods[provider.id]?.contains(where: { $0.isAPIKeyBased }) != true {
                            Text("Unsupported in MobileCode setup: requires non-API-key auth.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else {
                Text("Check runtime to load provider status.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            if let providerStatusWarning {
                Text(providerStatusWarning)
                    .font(.footnote)
                    .foregroundColor(.orange)
            }
        }

        Section("OpenCode Connection") {
            Picker("Provider", selection: $apiProviderID) {
                ForEach(apiKeyProviderChoices) { provider in
                    Text(provider.name).tag(provider.id)
                }
            }
            .accessibilityIdentifier("opencode-api-provider-picker")
            .onChange(of: apiProviderID) { _, _ in
                selectedModelID = ""
                selectedSmallModelID = ""
                applySuggestedModelsForSelectedProvider(overwriteExisting: false)
            }

            SecureField("API Key", text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("opencode-api-key-field")

            TextField("Default Model", text: $selectedModelID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("opencode-connection-model-field")

            TextField("Small Model", text: $selectedSmallModelID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("opencode-connection-small-model-field")

            if !selectedProviderModelChoices.isEmpty {
                Menu {
                    ForEach(selectedProviderModelChoices) { choice in
                        Button(choice.modelName) {
                            selectedModelID = choice.id
                            if selectedSmallModelID.isEmpty {
                                selectedSmallModelID = choice.id
                            }
                        }
                    }
                } label: {
                    Label("Choose \(selectedProviderDisplayName) Model", systemImage: "list.bullet")
                }
                .accessibilityIdentifier("opencode-connection-model-suggestions-menu")
            } else if let suggestedModelID = suggestedModelIDForSelectedProvider {
                Button {
                    selectedModelID = suggestedModelID
                    selectedSmallModelID = suggestedModelID
                } label: {
                    Label("Use \(suggestedModelID)", systemImage: "wand.and.stars")
                }
                .accessibilityIdentifier("opencode-connection-use-suggested-model-button")
            }

            HStack {
                Button("Load Stored") {
                    loadStoredOpenCodeAPIKey()
                }

                Spacer()

                Button {
                    Task { await saveProviderConnection(project: project) }
                } label: {
                    if isSavingProviderConnection {
                        ProgressView()
                    } else {
                        Text("Save Connection")
                    }
                }
                .disabled(
                    isSavingProviderConnection
                        || apiProviderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .accessibilityIdentifier("opencode-save-provider-connection-button")
            }

            Text("Choose a provider, paste its API key, and save. MobileCode writes the matching OpenCode provider and model config for this agent.")
                .font(.caption)
                .foregroundColor(.secondary)
        }

        Section("Advanced OpenCode Models") {
            Picker("Apply To", selection: $modelConfigScope) {
                ForEach(OpenCodeConfigurationScope.allCases) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .accessibilityIdentifier("opencode-model-scope-picker")
            .onChange(of: modelConfigScope) { _, _ in
                Task { await loadModelConfiguration(project: project) }
            }

            Picker("Default Model", selection: $selectedModelID) {
                Text("OpenCode Default").tag("")
                if let providerStatus {
                    ForEach(providerStatus.modelChoices) { choice in
                        Text(choice.label).tag(choice.id)
                    }
                }
            }
            .accessibilityIdentifier("opencode-default-model-picker")

            Picker("Small Model", selection: $selectedSmallModelID) {
                Text("OpenCode Default").tag("")
                if let providerStatus {
                    ForEach(providerStatus.modelChoices) { choice in
                        Text(choice.label).tag(choice.id)
                    }
                }
            }
            .accessibilityIdentifier("opencode-small-model-picker")

            Button {
                Task { await saveModelConfiguration(project: project) }
            } label: {
                if isSavingModelConfiguration {
                    ProgressView()
                } else {
                    Label("Save Model Selection", systemImage: "checkmark.circle")
                }
            }
            .disabled(isSavingModelConfiguration)
            .accessibilityIdentifier("opencode-save-model-selection-button")

            Text("Model ids are written to OpenCode config as provider/model, for example minimax/MiniMax-M2.7.")
                .font(.caption)
                .foregroundColor(.secondary)
        }

        Section("Custom OpenAI-Compatible Provider") {
            TextField("Provider ID", text: $customProviderID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Display Name", text: $customProviderName)
            TextField("Base URL", text: $customProviderBaseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("Model ID", text: $customProviderModelID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Model Name", text: $customProviderModelName)
            SecureField("API Key", text: $customProviderAPIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                Task { await saveCustomProvider(project: project) }
            } label: {
                if isSavingCustomProvider {
                    ProgressView()
                } else {
                    Label("Save Custom Provider", systemImage: "plus.circle")
                }
            }
            .disabled(
                isSavingCustomProvider
                    || customProviderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || customProviderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || customProviderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || customProviderModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || customProviderAPIKey.isEmpty
            )
            .accessibilityIdentifier("opencode-save-custom-provider-button")

            Text("Project-level custom providers still support API-key OpenAI-compatible endpoints. Use AI Provider Defaults above for global/server settings and OpenAI ChatGPT Plus/Pro mode.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var runtimeBinding: Binding<CodingAgentRuntimeKind> {
        Binding(
            get: { effectiveRuntime },
            set: { applyRuntimeSelection($0) }
        )
    }

    private var runtimeOptionsAccessibilityValue: String {
        CodingAgentRuntimeKind.allCases.map(\.displayName).joined(separator: ", ")
    }

    private func applyRuntimeSelection(_ runtime: CodingAgentRuntimeKind) {
        selectedRuntimeRawValue = runtime.rawValue
        runtimeSelectionStore.setSelectedRuntime(runtime)
        if let activeProject {
            activeProject.selectedAgentRuntime = runtime
            activeProject.updateLastModified()
            Task { await refreshStatus(for: activeProject) }
        }
    }

    private func refreshStatus(for project: RemoteProject) async {
        isLoadingStatus = true
        defer { isLoadingStatus = false }

        let runtime = CodingAgentRuntimeResolver.runtimeKind(for: project)
        runtimeHealth = await runtimeRegistry.runtime(for: runtime).health(for: project)

        guard runtime == .openCode else {
            providerStatus = nil
            return
        }

        do {
            providerStatus = try await providerService.status(for: project)
            providerStatusWarning = nil
            await loadModelConfiguration(project: project)
            applyUITestAIProviderAutofillIfNeeded()
            applySuggestedModelsForSelectedProvider(overwriteExisting: false)
        } catch {
            providerStatus = nil
            providerStatusWarning = "OpenCode provider status is unavailable. You can still enter a provider ID, save API keys, and configure models manually."
            applyUITestAIProviderAutofillIfNeeded()
            applySuggestedModelsForSelectedProvider(overwriteExisting: false)
        }
    }

    private func saveOpenCodeAPIKey(project: RemoteProject) async {
        isSavingAPIKey = true
        defer { isSavingAPIKey = false }

        do {
            try await providerService.saveAPIKey(apiKey, providerID: apiProviderID, for: project)
            apiKey = ""
            await refreshStatus(for: project)
        } catch {
            errorMessage = "Failed to save OpenCode API key: \(error.localizedDescription)"
            showError = true
        }
    }

    private func saveProviderConnection(project: RemoteProject) async {
        isSavingProviderConnection = true
        defer { isSavingProviderConnection = false }

        let trimmedProviderID = apiProviderID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModelID = selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? suggestedModelIDForSelectedProvider
        let resolvedSmallModelID = selectedSmallModelID.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? resolvedModelID

        do {
            if !trimmedAPIKey.isEmpty {
                try await providerService.saveAPIKey(trimmedAPIKey, providerID: trimmedProviderID, for: project)
                apiKey = ""
            }

            try await providerService.saveModelConfiguration(
                modelID: resolvedModelID,
                smallModelID: resolvedSmallModelID,
                scope: modelConfigScope,
                for: project
            )
            await refreshStatus(for: project)
        } catch {
            errorMessage = "Failed to save OpenCode provider connection: \(error.localizedDescription)"
            showError = true
        }
    }

    private func loadModelConfiguration(project: RemoteProject) async {
        do {
            let configuration = try await providerService.modelConfiguration(for: project, scope: modelConfigScope)
            selectedModelID = configuration.modelID ?? ""
            selectedSmallModelID = configuration.smallModelID ?? ""
        } catch {
            selectedModelID = ""
            selectedSmallModelID = ""
        }
    }

    private func saveModelConfiguration(project: RemoteProject) async {
        isSavingModelConfiguration = true
        defer { isSavingModelConfiguration = false }

        do {
            try await providerService.saveModelConfiguration(
                modelID: selectedModelID.isEmpty ? nil : selectedModelID,
                smallModelID: selectedSmallModelID.isEmpty ? nil : selectedSmallModelID,
                scope: modelConfigScope,
                for: project
            )
            await loadModelConfiguration(project: project)
        } catch {
            errorMessage = "Failed to save OpenCode model selection: \(error.localizedDescription)"
            showError = true
        }
    }

    private func saveCustomProvider(project: RemoteProject) async {
        isSavingCustomProvider = true
        defer { isSavingCustomProvider = false }

        do {
            try await providerService.saveCustomOpenAICompatibleProvider(
                OpenCodeCustomProviderInput(
                    id: customProviderID,
                    name: customProviderName,
                    baseURL: customProviderBaseURL,
                    modelID: customProviderModelID,
                    modelName: customProviderModelName,
                    apiKey: customProviderAPIKey
                ),
                scope: modelConfigScope,
                for: project
            )

            apiProviderID = customProviderID
            customProviderAPIKey = ""
            await refreshStatus(for: project)
        } catch {
            errorMessage = "Failed to save custom OpenCode provider: \(error.localizedDescription)"
            showError = true
        }
    }

    @discardableResult
    private func applyUITestAIProviderAutofillIfNeeded(
        processInfo: ProcessInfo = .processInfo
    ) -> Bool {
        guard processInfo.arguments.contains("--ui-testing"),
              processInfo.environment["MOBILECODE_E2E_AUTOFILL_AI_API_KEY"] == "1" else {
            return false
        }

        var didApply = false
        let environment = processInfo.environment
        if let providerID = environment["MOBILECODE_E2E_AI_PROVIDER_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !providerID.isEmpty {
            apiProviderID = providerID
            didApply = true
        }
        if let e2eAPIKey = environment["MOBILECODE_E2E_AI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !e2eAPIKey.isEmpty {
            apiKey = e2eAPIKey
            didApply = true
        }
        if let modelID = environment["MOBILECODE_E2E_AI_MODEL_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !modelID.isEmpty {
            selectedModelID = modelID
            didApply = true
        }
        if let smallModelID = environment["MOBILECODE_E2E_AI_SMALL_MODEL_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !smallModelID.isEmpty {
            selectedSmallModelID = smallModelID
            didApply = true
        }

        return didApply
    }

    private var selectedProviderDisplayName: String {
        apiKeyProviderChoices.first { $0.id.caseInsensitiveCompare(apiProviderID) == .orderedSame }?.name
            ?? apiProviderID
    }

    private var suggestedModelIDForSelectedProvider: String? {
        OpenCodeProviderConnectionDefaults.suggestedModelID(providerID: apiProviderID, status: providerStatus)
    }

    private func applySuggestedModelsForSelectedProvider(overwriteExisting: Bool) {
        guard let suggestedModelID = suggestedModelIDForSelectedProvider else { return }
        if overwriteExisting || selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectedModelID = suggestedModelID
        }
        if overwriteExisting || selectedSmallModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectedSmallModelID = selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? suggestedModelID
        }
    }

    private func loadStoredOpenCodeAPIKey() {
        do {
            apiKey = try KeychainManager.shared.retrieveOpenCodeAPIKey(providerID: apiProviderID)
        } catch {
            if applyUITestAIProviderAutofillIfNeeded() {
                return
            }
            apiKey = ""
            errorMessage = "No stored key found for \(apiProviderID)."
            showError = true
        }
    }

    private func healthText(_ health: CodingAgentRuntimeHealth) -> String {
        switch health.status {
        case .available:
            return "Available"
        case .unavailable:
            return "Unavailable"
        case .unknown:
            return "Unknown"
        }
    }
}

#Preview {
    NavigationStack {
        AgentRuntimeSettingsView()
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
