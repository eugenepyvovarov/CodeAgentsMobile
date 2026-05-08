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
    let navigationTitle: String?

    @Query(sort: \Server.name) private var servers: [Server]
    @StateObject private var providerService = OpenCodeProviderService.shared

    @State private var useGlobalDefaults = true
    @State private var profile = OpenCodeAIProviderProfile.defaults()
    @State private var apiKey = ""
    @State private var customProviderEnabled = false
    @State private var showProviderPicker = false
    @State private var showModelPicker = false
    @State private var showAdvancedModels = false
    @State private var confirmApplyAll = false
    @State private var confirmRemoveAuth = false
    @State private var removeAuthFromAllServers = false
    @State private var providerStatus: OpenCodeProviderStatus?
    @State private var statusSourceName: String?
    @State private var isApplying = false
    @State private var isRemovingAuth = false
    @State private var isRefreshingStatus = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var isStartingChatGPTOAuth = false
    @State private var isCompletingChatGPTOAuth = false
    @State private var chatGPTOAuthAuthorization: OpenCodeProviderOAuthAuthorization?
    @State private var chatGPTOAuthMethodIndex: Int?
    @State private var chatGPTOAuthCode = ""
    @State private var copiedChatGPTConfirmationCode = false
    @State private var chatGPTOAuthCompletedServerID: UUID?

    private let settingsStore = OpenCodeAIProviderSettingsStore()

    init(server: Server? = nil, navigationTitle: String? = nil) {
        self.server = server
        self.navigationTitle = navigationTitle
    }

    var body: some View {
        Form {
            scopeSection
            connectionSection
            modelSection
            advancedSection
            applySection
            statusSection
        }
        .navigationTitle(navigationTitle ?? (server == nil ? "OpenCode AI" : "Server AI"))
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
                selectModel(choice)
                showModelPicker = false
            }
        }
        .confirmationDialog(
            "Apply OpenCode AI settings to every server?",
            isPresented: $confirmApplyAll,
            titleVisibility: .visible
        ) {
            Button("Apply to \(servers.count) Server\(servers.count == 1 ? "" : "s")") {
                Task { await applyGlobalSettingsToAllServers() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This updates the provider, credential, and selected model on each server.")
        }
        .confirmationDialog(
            removeAuthFromAllServers ? "Remove \(selectedProviderName) auth from every server?" : "Remove \(selectedProviderName) auth from \(authActionTargetServer?.name ?? "this server")?",
            isPresented: $confirmRemoveAuth,
            titleVisibility: .visible
        ) {
            Button(removeAuthFromAllServers ? "Remove from All Servers" : "Remove Auth", role: .destructive) {
                Task { await removeSelectedProviderAuth() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected provider credential from OpenCode. You can reconnect it immediately after.")
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

    private var connectionSection: some View {
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

            if supportsChatGPTAuth {
                Picker("Sign in with", selection: authModeBinding) {
                    Text("API Key").tag(OpenCodeProviderAuthMode.apiKey)
                    Text("ChatGPT Plus/Pro").tag(OpenCodeProviderAuthMode.openAIChatGPT)
                }
                .pickerStyle(.segmented)
                .disabled(editsDisabled)
                .accessibilityIdentifier("opencode-ai-auth-mode-picker")
            } else if selectedProviderUsesNoCredential {
                LabeledContent("Sign in with") {
                    Text("No key")
                        .foregroundColor(.secondary)
                }
            } else {
                LabeledContent("Sign in with") {
                    Text("API Key")
                        .foregroundColor(.secondary)
                }
            }

            if selectedProviderUsesNoCredential {
                Label("No API key required", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.footnote)
            } else if profile.requiresAPIKeyCredential {
                if providerConnectedInStatus {
                    Label("\(selectedProviderName) is authorized on \(statusSourceName ?? "the server")", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.footnote)
                }

                SecureField(providerConnectedInStatus ? "Replace API Key on Server" : "API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(editsDisabled)
                    .accessibilityIdentifier("opencode-ai-api-key-field")
            } else {
                chatGPTConnectionView
            }

            authRemovalControls
        } header: {
            Text("Connection")
        } footer: {
            Text(credentialFooterText)
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
    }

    @ViewBuilder
    private var chatGPTConnectionView: some View {
        if providerConnectedInStatus {
            Label("OpenAI is connected on \(statusSourceName ?? "the server")", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.footnote)

            Text("Remove auth below to sign in with a different OpenAI account.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else if chatGPTOAuthCompletedForTargetServer {
            Label("OpenAI authorization completed on \(chatGPTOAuthTargetServer?.name ?? "the server")", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.footnote)

            Text("Apply to validate the selected model after OpenCode refreshes its provider cache.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else if chatGPTOAuthTargetServer == nil {
            Label("Add a server before using ChatGPT Plus/Pro", systemImage: "server.rack")
                .foregroundStyle(.secondary)
                .font(.footnote)
        } else if chatGPTOAuthMethod == nil {
            Label("ChatGPT Plus/Pro login is not available from this OpenCode server", systemImage: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.secondary)
                .font(.footnote)

            Text("Refresh providers or use API Key. Do not type /connect in CodeAgents chat; slash commands there are treated as skills.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else if let authorization = chatGPTOAuthAuthorization {
            chatGPTOAuthCompletionView(authorization)
        } else {
            Label("OpenAI login will open in your browser", systemImage: "safari")
                .foregroundStyle(.secondary)
                .font(.footnote)

            Button {
                Task { await startChatGPTOAuth() }
            } label: {
                savingLabel(isWorking: isStartingChatGPTOAuth, title: "Start ChatGPT Login", systemImage: "person.crop.circle.badge.plus")
            }
            .disabled(editsDisabled || isStartingChatGPTOAuth)
            .accessibilityIdentifier("opencode-ai-start-chatgpt-login-button")
        }
    }

    @ViewBuilder
    private func chatGPTOAuthCompletionView(_ authorization: OpenCodeProviderOAuthAuthorization) -> some View {
        if let url = URL(string: authorization.url) {
            Link(destination: url) {
                Label("Open OpenAI Login", systemImage: "arrow.up.forward.app")
            }
            .accessibilityIdentifier("opencode-ai-open-chatgpt-login-link")
        } else {
            Text(authorization.url)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .foregroundColor(.secondary)
        }

        if let confirmationCode = chatGPTConfirmationCode(from: authorization.instructions) {
            LabeledContent("Code") {
                HStack(spacing: 8) {
                    Text(confirmationCode)
                        .font(.body.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                    Button {
                        copyChatGPTConfirmationCode(confirmationCode)
                    } label: {
                        Image(systemName: copiedChatGPTConfirmationCode ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(copiedChatGPTConfirmationCode ? "Copied code" : "Copy code")
                }
            }
        } else if !authorization.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(authorization.instructions)
                .font(.caption)
                .foregroundColor(.secondary)
        }

        if authorization.isCodeBased {
            TextField("Authorization Code", text: $chatGPTOAuthCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("opencode-ai-chatgpt-authorization-code-field")
        }

        Button {
            Task { await completeChatGPTOAuth() }
        } label: {
            savingLabel(
                isWorking: isCompletingChatGPTOAuth,
                title: authorization.isCodeBased ? "Complete Login" : "I Finished in Browser",
                systemImage: "checkmark.circle"
            )
        }
        .disabled(editsDisabled || isCompletingChatGPTOAuth || (authorization.isCodeBased && chatGPTOAuthCode.trimmedOpenCodeValue.isEmpty))
        .accessibilityIdentifier("opencode-ai-complete-chatgpt-login-button")

        Button(role: .cancel) {
            resetChatGPTOAuthState()
        } label: {
            Label("Cancel Login", systemImage: "xmark.circle")
        }
        .disabled(isCompletingChatGPTOAuth)

        Text("Finish the browser login, then return here.")
            .font(.caption)
            .foregroundColor(.secondary)
    }

    @ViewBuilder
    private var authRemovalControls: some View {
        if canRemoveProviderAuth, server == nil {
            Button(role: .destructive) {
                removeAuthFromAllServers = true
                confirmRemoveAuth = true
            } label: {
                savingLabel(
                    isWorking: isRemovingAuth,
                    title: "Remove Auth on All Servers",
                    systemImage: "person.2.crop.square.stack.fill"
                )
            }
            .disabled(editsDisabled || isRemovingAuth)
            .accessibilityIdentifier("opencode-ai-remove-auth-all-servers-button")
        } else if canRemoveProviderAuth, let targetServer = authActionTargetServer {
            Button(role: .destructive) {
                removeAuthFromAllServers = false
                confirmRemoveAuth = true
            } label: {
                savingLabel(
                    isWorking: isRemovingAuth,
                    title: "Remove Auth on \(targetServer.name)",
                    systemImage: "person.crop.circle.badge.xmark"
                )
            }
            .disabled(editsDisabled || isRemovingAuth)
            .accessibilityIdentifier("opencode-ai-remove-auth-server-button")
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
                            Text(selectedModelSubtitle)
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

                if selectedModelUnavailable {
                    Label("Selected model is not available for \(selectedProviderName). Choose another model.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }

        } header: {
            Text("Model")
        }
    }

    private var advancedSection: some View {
        Section {
            if customProviderEnabled {
                Picker("API Style", selection: npmDriverBinding) {
                    ForEach(OpenCodeProviderNPMDriver.allCases) { driver in
                        Text(driver.displayName).tag(driver)
                    }
                }
                .disabled(editsDisabled)
            }

            DisclosureGroup("Small Model Override", isExpanded: $showAdvancedModels) {
                TextField("Small Model Override", text: $profile.smallModelID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(editsDisabled)
                    .accessibilityIdentifier("opencode-ai-small-model-id-field")

                Button {
                    profile.smallModelID = ""
                } label: {
                    Label("Use Selected Model", systemImage: "arrow.down.circle")
                }
                .disabled(editsDisabled || profile.smallModelID.trimmedOpenCodeValue.isEmpty)
                .accessibilityIdentifier("opencode-ai-use-selected-small-model-button")
            }
        } header: {
            Text("Advanced")
        }
    }

    private var applySection: some View {
        Section {
            if let server {
                Button {
                    Task { await applySettings(to: server) }
                } label: {
                    savingLabel(isWorking: isApplying, title: "Apply to This Server", systemImage: "checkmark.circle")
                }
                .disabled(isApplying || !canApply)
                .accessibilityIdentifier("opencode-ai-apply-server-button")
            } else {
                Button {
                    confirmApplyAll = true
                } label: {
                    savingLabel(isWorking: isApplying, title: "Apply to All Servers", systemImage: "checkmark.circle")
                }
                .disabled(isApplying || servers.isEmpty || !canApply)
                .accessibilityIdentifier("opencode-ai-apply-all-servers-button")
            }

        } header: {
            Text("Apply")
        } footer: {
            Text("Apply writes the provider and model to OpenCode, then validates the selected model on the target server.")
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
                resetChatGPTOAuthState()
                if newValue != .openAIChatGPT {
                    chatGPTOAuthCompletedServerID = nil
                }
                if newValue == .openAIChatGPT {
                    profile.providerID = "openai"
                    profile.providerName = "OpenAI"
                    customProviderEnabled = false
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
        return providerStatus?.modelChoices(for: profile.normalizedProviderID) ?? []
    }

    private var selectedModelUnavailable: Bool {
        guard let modelID = profile.resolvedModelID?.trimmedOpenCodeValue,
              !modelID.isEmpty,
              !selectedProviderModelChoices.isEmpty else {
            return false
        }
        return selectedProviderModelChoices.contains { choice in
            choice.id.caseInsensitiveCompare(modelID) == .orderedSame
        } == false
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
        if providerConnectedInStatus {
            return "Connected in OpenCode"
        }
        if chatGPTOAuthCompletedForTargetServer {
            return "Authorized on server"
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
        if selectedModelUnavailable {
            return "Choose Model"
        }
        return modelID
    }

    private var selectedModelSubtitle: String {
        let countText = "\(selectedProviderModelChoices.count) model\(selectedProviderModelChoices.count == 1 ? "" : "s")"
        guard let modelID = profile.resolvedModelID,
              let choice = selectedProviderModelChoices.first(where: { $0.id.caseInsensitiveCompare(modelID) == .orderedSame }),
              choice.modelName.caseInsensitiveCompare(choice.modelID) != .orderedSame else {
            return countText
        }
        return "\(choice.modelName) · \(countText)"
    }

    private var supportsChatGPTAuth: Bool {
        profile.normalizedProviderID == "openai" && !customProviderEnabled
    }

    private var selectedProviderUsesNoCredential: Bool {
        profile.normalizedProviderID == "opencode" && !customProviderEnabled
    }

    private var providerIsConnected: Bool {
        providerConnectedInStatus || chatGPTOAuthCompletedForTargetServer
    }

    private var providerConnectedInStatus: Bool {
        providerStatus?.isAuthenticated(providerID: profile.normalizedProviderID) == true
    }

    private var canRemoveProviderAuth: Bool {
        guard !selectedProviderUsesNoCredential,
              !profile.normalizedProviderID.isEmpty else {
            return false
        }
        if server == nil {
            return !servers.isEmpty
        }
        return providerConnectedInStatus && authActionTargetServer != nil
    }

    private var chatGPTOAuthCompletedForTargetServer: Bool {
        guard profile.authMode == .openAIChatGPT,
              profile.normalizedProviderID == "openai",
              let targetServer = chatGPTOAuthTargetServer else {
            return false
        }
        return chatGPTOAuthCompletedServerID == targetServer.id
    }

    private var modelStepComplete: Bool {
        profile.resolvedModelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && !selectedModelUnavailable
    }

    private var canApply: Bool {
        guard profile.isReadyToSave else { return false }
        guard modelStepComplete else { return false }
        if selectedProviderUsesNoCredential {
            return true
        }
        if profile.requiresAPIKeyCredential {
            return providerConnectedInStatus || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return providerIsConnected
    }

    private var credentialFooterText: String {
        if selectedProviderUsesNoCredential {
            return "OpenCode bundled models do not need a provider API key."
        }
        if profile.requiresAPIKeyCredential {
            return "Paste a key to authorize or replace the provider on the server. Leave it empty to use an auth that already exists on that server."
        }
        return "ChatGPT Plus/Pro uses OpenCode's OAuth flow on the server. CodeAgents only shows the link and code; it does not store the OpenAI credential."
    }

    private var authActionTargetServer: Server? {
        server ?? servers.first
    }

    private var chatGPTOAuthTargetServer: Server? {
        server ?? servers.first
    }

    private var chatGPTOAuthMethod: (index: Int, method: OpenCodeProviderAuthMethod)? {
        let methods = providerStatus?.authMethods.first(where: { key, _ in
            key.caseInsensitiveCompare("openai") == .orderedSame
        })?.value ?? []
        let oauthMethods = methods.enumerated().filter { $0.element.isOAuthBased }
        guard !oauthMethods.isEmpty else { return nil }

        let preferred = oauthMethods.first { item in
            let label = item.element.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return label.contains("headless") || label.contains("device")
        } ?? oauthMethods.first { item in
            let label = item.element.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return label.contains("chatgpt") || label.contains("plus") || label.contains("pro")
        } ?? oauthMethods[0]

        return (preferred.offset, preferred.element)
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

    private func copyChatGPTConfirmationCode(_ code: String) {
        UIPasteboard.general.string = code
        copiedChatGPTConfirmationCode = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copiedChatGPTConfirmationCode = false
        }
    }

    private func chatGPTConfirmationCode(from instructions: String) -> String? {
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let range = trimmed.range(of: "code:", options: [.caseInsensitive]) {
            let suffix = trimmed[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return suffix.isEmpty ? nil : suffix
        }
        return nil
    }

    private func resetChatGPTOAuthState() {
        chatGPTOAuthAuthorization = nil
        chatGPTOAuthMethodIndex = nil
        chatGPTOAuthCode = ""
        copiedChatGPTConfirmationCode = false
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
        resetChatGPTOAuthState()
        repairSelectedModelIfNeeded()
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
        resetChatGPTOAuthState()
        repairSelectedModelIfNeeded()
    }

    private func selectProvider(_ choice: OpenCodeProviderChoice) {
        let didChangeProvider = choice.id.caseInsensitiveCompare(profile.normalizedProviderID) != .orderedSame
        resetChatGPTOAuthState()
        if didChangeProvider || choice.isCustom || !choice.supportsChatGPT {
            chatGPTOAuthCompletedServerID = nil
        }

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
            profile.smallModelID = ""
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
            if didChangeProvider {
                profile.modelID = ""
                profile.smallModelID = ""
            }
            if profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.modelID = OpenCodeProviderConnectionDefaults.suggestedModelID(
                    providerID: choice.id,
                    status: providerStatus
                ) ?? ""
            }
        }
        repairSelectedModelIfNeeded()
        apiKey = ""
    }

    private func selectModel(_ choice: OpenCodeModelChoice) {
        let previousModelID = profile.modelID.trimmedOpenCodeValue
        let previousSmallModelID = profile.smallModelID.trimmedOpenCodeValue
        let previousSuggestedSmallModelID = OpenCodeProviderConnectionDefaults.suggestedSmallModelID(
            providerID: profile.normalizedProviderID,
            status: providerStatus
        )?.trimmedOpenCodeValue ?? ""
        let shouldClearSmallModelOverride = previousSmallModelID.isEmpty
            || previousSmallModelID == previousModelID
            || (!previousSuggestedSmallModelID.isEmpty && previousSmallModelID == previousSuggestedSmallModelID)

        profile.modelID = choice.id
        if shouldClearSmallModelOverride {
            profile.smallModelID = ""
        }
    }

    private func clearAutoFilledSmallModelOverrideIfNeeded() {
        let smallModelID = profile.smallModelID.trimmedOpenCodeValue
        guard !smallModelID.isEmpty,
              let modelID = profile.resolvedModelID?.trimmedOpenCodeValue,
              !modelID.isEmpty,
              smallModelID != modelID else {
            return
        }

        let suggestedSmallModelID = OpenCodeProviderConnectionDefaults.suggestedSmallModelID(
            providerID: profile.normalizedProviderID,
            status: providerStatus
        )?.trimmedOpenCodeValue
        if suggestedSmallModelID == smallModelID {
            profile.smallModelID = ""
        }
    }

    private func repairSelectedModelIfNeeded() {
        guard !customProviderEnabled, !selectedProviderModelChoices.isEmpty else { return }

        let currentModelID = profile.modelID.trimmedOpenCodeValue
        if currentModelID.isEmpty {
            return
        }

        let currentModelIsAvailable = selectedProviderModelChoices.contains { choice in
            choice.id.caseInsensitiveCompare(currentModelID) == .orderedSame
        }
        guard !currentModelIsAvailable else { return }

        let suggestedModelID = OpenCodeProviderConnectionDefaults.suggestedModelID(
            providerID: profile.normalizedProviderID,
            status: providerStatus
        )?.trimmedOpenCodeValue

        if let suggestedModelID,
           selectedProviderModelChoices.contains(where: { $0.id.caseInsensitiveCompare(suggestedModelID) == .orderedSame }) {
            profile.modelID = suggestedModelID
        } else {
            profile.modelID = ""
        }

        let smallModelID = profile.smallModelID.trimmedOpenCodeValue
        if smallModelID.isEmpty || smallModelID.caseInsensitiveCompare(currentModelID) == .orderedSame {
            profile.smallModelID = ""
        }
    }

    @MainActor
    private func startChatGPTOAuth() async {
        guard let targetServer = chatGPTOAuthTargetServer,
              let oauthMethod = chatGPTOAuthMethod else {
            return
        }

        isStartingChatGPTOAuth = true
        defer { isStartingChatGPTOAuth = false }

        do {
            chatGPTOAuthCompletedServerID = nil
            let authorization = try await providerService.startOAuth(
                providerID: "openai",
                methodIndex: oauthMethod.index,
                on: targetServer
            )
            chatGPTOAuthAuthorization = authorization
            chatGPTOAuthMethodIndex = oauthMethod.index
            chatGPTOAuthCode = ""
            statusMessage = "Open the login link, finish OpenAI authorization, then return here."
        } catch {
            present(error)
        }
    }

    @MainActor
    private func completeChatGPTOAuth() async {
        guard let targetServer = chatGPTOAuthTargetServer,
              let methodIndex = chatGPTOAuthMethodIndex,
              let authorization = chatGPTOAuthAuthorization else {
            return
        }

        let code = authorization.isCodeBased ? chatGPTOAuthCode.trimmedOpenCodeValue : nil
        if authorization.isCodeBased, code?.isEmpty != false {
            present(OpenCodeProviderServiceError.invalidInput)
            return
        }

        isCompletingChatGPTOAuth = true
        defer { isCompletingChatGPTOAuth = false }

        do {
            try await providerService.completeOAuth(
                providerID: "openai",
                methodIndex: methodIndex,
                code: code,
                on: targetServer
            )
            chatGPTOAuthCompletedServerID = targetServer.id
            resetChatGPTOAuthState()
            statusMessage = "OpenAI connected on \(targetServer.name)."
            await refreshProviderStatusIfPossible()
        } catch {
            present(error)
        }
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
            repairSelectedModelIfNeeded()
            clearAutoFilledSmallModelOverrideIfNeeded()
            if profile.authMode != .openAIChatGPT || profile.normalizedProviderID != "openai" {
                chatGPTOAuthCompletedServerID = nil
            }
        } catch {
            statusMessage = "Provider list unavailable. You can still connect a provider manually."
        }
    }

    @discardableResult
    private func persistSelection() throws -> OpenCodeAIProviderProfile {
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
        } else {
            try settingsStore.saveGlobalProfile(normalized)
        }
        return normalized
    }

    @MainActor
    private func applySettings(to targetServer: Server) async {
        isApplying = true
        defer { isApplying = false }

        do {
            let normalized = try persistSelection()
            let apiKeyToApply = apiKey.trimmedOpenCodeValue.nilIfEmpty

            let profileToApply: OpenCodeAIProviderProfile
            if let sourceServer = server {
                profileToApply = settingsStore.effectiveProfile(for: sourceServer.id)
            } else {
                profileToApply = normalized
            }

            try await providerService.applyAIProviderProfile(
                profileToApply,
                apiKey: apiKeyToApply,
                to: targetServer
            )
            apiKey = ""
            statusMessage = "Applied and validated on \(targetServer.name)."
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
            let globalProfile = try persistSelection()
            let apiKeyToApply = apiKey.trimmedOpenCodeValue.nilIfEmpty
            for targetServer in servers {
                try await providerService.applyAIProviderProfile(
                    globalProfile,
                    apiKey: apiKeyToApply,
                    to: targetServer
                )
            }
            apiKey = ""
            statusMessage = "Applied and validated on \(servers.count) server\(servers.count == 1 ? "" : "s")."
            await refreshProviderStatusIfPossible()
        } catch {
            present(error)
        }
    }

    @MainActor
    private func removeSelectedProviderAuth() async {
        let normalizedProviderID = profile.normalizedProviderID
        guard !normalizedProviderID.isEmpty else {
            present(OpenCodeProviderServiceError.invalidInput)
            return
        }

        let targetServers: [Server]
        if removeAuthFromAllServers {
            targetServers = servers
        } else if let authActionTargetServer {
            targetServers = [authActionTargetServer]
        } else {
            present(OpenCodeProviderServiceError.invalidInput)
            return
        }

        guard !targetServers.isEmpty else {
            present(OpenCodeProviderServiceError.invalidInput)
            return
        }

        isRemovingAuth = true
        defer { isRemovingAuth = false }

        do {
            for targetServer in targetServers {
                try await providerService.removeAuth(providerID: normalizedProviderID, on: targetServer)
            }
            deleteLocalAPIKeyIfPresent(for: normalizedProviderID, targetServers: targetServers)
            apiKey = ""
            chatGPTOAuthCompletedServerID = nil
            resetChatGPTOAuthState()
            let count = targetServers.count
            statusMessage = "Removed \(selectedProviderName) auth from \(count) server\(count == 1 ? "" : "s")."
            await refreshProviderStatusIfPossible()
        } catch {
            present(error)
        }
    }

    private func deleteLocalAPIKeyIfPresent(for providerID: String, targetServers: [Server]) {
        try? KeychainManager.shared.deleteOpenCodeAPIKey(providerID: providerID)
        for targetServer in targetServers {
            try? KeychainManager.shared.deleteOpenCodeAPIKey(providerID: providerID, serverID: targetServer.id)
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
                            Text(choice.id)
                                .foregroundColor(.primary)
                            Text(modelSubtitle(for: choice))
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

    private func modelSubtitle(for choice: OpenCodeModelChoice) -> String {
        if choice.modelName.caseInsensitiveCompare(choice.modelID) == .orderedSame {
            return choice.providerName
        }
        return "\(choice.modelName) · \(choice.providerName)"
    }
}

private extension String {
    var trimmedOpenCodeValue: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

#Preview {
    NavigationStack {
        OpenCodeAIProviderSettingsView()
    }
    .modelContainer(for: [Server.self], inMemory: true)
}
