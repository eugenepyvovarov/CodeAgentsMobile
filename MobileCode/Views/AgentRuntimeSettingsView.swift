//
//  AgentRuntimeSettingsView.swift
//  CodeAgentsMobile
//
//  Purpose: Runtime and OpenCode provider settings
//

import SwiftUI

struct AgentRuntimeSettingsView: View {
    @StateObject private var projectContext = ProjectContext.shared
    @AppStorage(CodingAgentRuntimeSelectionStore.selectedRuntimeKey) private var selectedRuntimeRawValue = CodingAgentRuntimeSelectionStore.defaultRuntime.rawValue

    @StateObject private var providerService = OpenCodeProviderService.shared
    @State private var runtimeHealth: CodingAgentRuntimeHealth?
    @State private var providerStatus: OpenCodeProviderStatus?
    @State private var apiProviderID = "anthropic"
    @State private var apiKey = ""
    @State private var isLoadingStatus = false
    @State private var isSavingAPIKey = false
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

    var body: some View {
        Form {
            Section {
                Picker("Runtime", selection: runtimeBinding) {
                    ForEach(CodingAgentRuntimeKind.allCases) { runtime in
                        Text(runtime.displayName).tag(runtime)
                    }
                }

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
        .task {
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
                    }
                    .padding(.vertical, 2)
                }
            } else {
                Text("Check runtime to load provider status.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }

        Section("OpenCode API Key") {
            TextField("Provider ID", text: $apiProviderID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("API Key", text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            HStack {
                Button("Load Stored") {
                    loadStoredOpenCodeAPIKey()
                }

                Spacer()

                Button {
                    Task { await saveOpenCodeAPIKey(project: project) }
                } label: {
                    if isSavingAPIKey {
                        ProgressView()
                    } else {
                        Text("Save to OpenCode")
                    }
                }
                .disabled(isSavingAPIKey || apiProviderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiKey.isEmpty)
            }

            Text("OpenCode owns provider configuration on the server. MobileCode stores this key under an OpenCode-specific keychain entry and sends it to the selected server.")
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
        } catch {
            providerStatus = nil
            errorMessage = "Failed to load OpenCode providers: \(error.localizedDescription)"
            showError = true
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

    private func loadStoredOpenCodeAPIKey() {
        do {
            apiKey = try KeychainManager.shared.retrieveOpenCodeAPIKey(providerID: apiProviderID)
        } catch {
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
