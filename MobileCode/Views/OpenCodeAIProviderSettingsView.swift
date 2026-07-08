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

    @Query(sort: \Server.name) var servers: [Server]
    @StateObject var providerService = OpenCodeProviderService.shared

    @State var useGlobalDefaults = true
    @State var profile = OpenCodeAIProviderProfile.defaults()
    @State var apiKey = ""
    @State var customProviderEnabled = false
    @State var showProviderPicker = false
    @State var showModelPicker = false
    @State var showAdvancedModels = false
    @State var confirmApplyAll = false
    @State var confirmRemoveAuth = false
    @State var removeAuthFromAllServers = false
    @State var providerStatus: OpenCodeProviderStatus?
    @State var statusSourceName: String?
    @State var isApplying = false
    @State var isRemovingAuth = false
    @State var isRefreshingStatus = false
    @State var statusMessage: String?
    @State var errorMessage: String?
    @State var showError = false
    @State var isStartingChatGPTOAuth = false
    @State var isCompletingChatGPTOAuth = false
    @State var chatGPTOAuthAuthorization: OpenCodeProviderOAuthAuthorization?
    @State var chatGPTOAuthMethodIndex: Int?
    @State var chatGPTOAuthCode = ""
    @State var copiedChatGPTConfirmationCode = false
    @State var chatGPTOAuthCompletedServerID: UUID?

    let settingsStore = OpenCodeAIProviderSettingsStore()

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

    var authModeBinding: Binding<OpenCodeProviderAuthMode> {
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

    var npmDriverBinding: Binding<OpenCodeProviderNPMDriver> {
        Binding(
            get: { profile.npmDriver },
            set: { profile.npmDriver = $0 }
        )
    }

    var providerChoices: [OpenCodeProviderChoice] {
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

    var selectedProviderModelChoices: [OpenCodeModelChoice] {
        guard !profile.normalizedProviderID.isEmpty else { return [] }
        return providerStatus?.modelChoices(for: profile.normalizedProviderID) ?? []
    }

    var selectedModelUnavailable: Bool {
        guard let modelID = profile.resolvedModelID?.trimmedOpenCodeValue,
              !modelID.isEmpty,
              !selectedProviderModelChoices.isEmpty else {
            return false
        }
        return selectedProviderModelChoices.contains { choice in
            choice.id.caseInsensitiveCompare(modelID) == .orderedSame
        } == false
    }

    var selectedProviderName: String {
        if customProviderEnabled {
            let name = profile.providerName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Other" : name
        }
        return OpenCodeProviderPreset.name(for: profile.normalizedProviderID) ?? profile.trimmedProviderName
    }

    var selectedProviderSubtitle: String {
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

    var selectedProviderSymbol: String {
        customProviderEnabled ? "plus.circle" : OpenCodeProviderPreset.symbol(for: profile.normalizedProviderID)
    }

    var selectedModelTitle: String {
        guard let modelID = profile.resolvedModelID, !modelID.isEmpty else {
            return "Choose Model"
        }
        if selectedModelUnavailable {
            return "Choose Model"
        }
        return modelID
    }

    var selectedModelSubtitle: String {
        let countText = "\(selectedProviderModelChoices.count) model\(selectedProviderModelChoices.count == 1 ? "" : "s")"
        guard let modelID = profile.resolvedModelID,
              let choice = selectedProviderModelChoices.first(where: { $0.id.caseInsensitiveCompare(modelID) == .orderedSame }),
              choice.modelName.caseInsensitiveCompare(choice.modelID) != .orderedSame else {
            return countText
        }
        return "\(choice.modelName) · \(countText)"
    }

    var supportsChatGPTAuth: Bool {
        profile.normalizedProviderID == "openai" && !customProviderEnabled
    }

    var selectedProviderUsesNoCredential: Bool {
        profile.normalizedProviderID == "opencode" && !customProviderEnabled
    }

    var providerIsConnected: Bool {
        providerConnectedInStatus || chatGPTOAuthCompletedForTargetServer
    }

    var providerConnectedInStatus: Bool {
        providerStatus?.isAuthenticated(providerID: profile.normalizedProviderID) == true
    }

    var canUseLegacyAPIKeyForOpenCode: Bool {
        guard profile.requiresAPIKeyCredential,
              !customProviderEnabled,
              !profile.normalizedProviderID.isEmpty else {
            return false
        }
        return AIProviderCredentialMigration.canCopyLegacyAPIKeyForOpenCode(providerID: profile.normalizedProviderID)
    }

    var canRemoveProviderAuth: Bool {
        guard !selectedProviderUsesNoCredential,
              !profile.normalizedProviderID.isEmpty else {
            return false
        }
        if server == nil {
            return !servers.isEmpty
        }
        return providerConnectedInStatus && authActionTargetServer != nil
    }

    var chatGPTOAuthCompletedForTargetServer: Bool {
        guard profile.authMode == .openAIChatGPT,
              profile.normalizedProviderID == "openai",
              let targetServer = chatGPTOAuthTargetServer else {
            return false
        }
        return chatGPTOAuthCompletedServerID == targetServer.id
    }

    var modelStepComplete: Bool {
        profile.resolvedModelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && !selectedModelUnavailable
    }

    var canApply: Bool {
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

    var credentialFooterText: String {
        if selectedProviderUsesNoCredential {
            return "OpenCode bundled models do not need a provider API key."
        }
        if profile.requiresAPIKeyCredential {
            return "Paste a key to authorize or replace the provider on the server. Leave it empty to use an auth that already exists on that server."
        }
        return "ChatGPT Plus/Pro uses OpenCode's OAuth flow on the server. CodeAgents only shows the link and code; it does not store the OpenAI credential."
    }

    var authActionTargetServer: Server? {
        server ?? servers.first
    }

    var chatGPTOAuthTargetServer: Server? {
        server ?? servers.first
    }

    var chatGPTOAuthMethod: (index: Int, method: OpenCodeProviderAuthMethod)? {
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

    func savingLabel(isWorking: Bool, title: String, systemImage: String) -> some View {
        HStack {
            if isWorking {
                ProgressView()
            } else {
                Label(title, systemImage: systemImage)
            }
        }
    }

    func copyChatGPTConfirmationCode(_ code: String) {
        UIPasteboard.general.string = code
        copiedChatGPTConfirmationCode = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copiedChatGPTConfirmationCode = false
        }
    }

    func chatGPTConfirmationCode(from instructions: String) -> String? {
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let range = trimmed.range(of: "code:", options: [.caseInsensitive]) {
            let suffix = trimmed[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return suffix.isEmpty ? nil : suffix
        }
        return nil
    }

    func resetChatGPTOAuthState() {
        chatGPTOAuthAuthorization = nil
        chatGPTOAuthMethodIndex = nil
        chatGPTOAuthCode = ""
        copiedChatGPTConfirmationCode = false
    }

    func loadSettings() {
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

    func loadServerScope(useGlobalDefaults: Bool) {
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

    func selectProvider(_ choice: OpenCodeProviderChoice) {
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

    func selectModel(_ choice: OpenCodeModelChoice) {
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

    func clearAutoFilledSmallModelOverrideIfNeeded() {
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

    func repairSelectedModelIfNeeded() {
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
    func startChatGPTOAuth() async {
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
    func completeChatGPTOAuth() async {
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
    func refreshProviderStatusIfPossible() async {
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
    func persistSelection() throws -> OpenCodeAIProviderProfile {
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
    func applySettings(to targetServer: Server) async {
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
    func applyGlobalSettingsToAllServers() async {
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
    func removeSelectedProviderAuth() async {
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

    func deleteLocalAPIKeyIfPresent(for providerID: String, targetServers: [Server]) {
        try? KeychainManager.shared.deleteOpenCodeAPIKey(providerID: providerID)
        for targetServer in targetServers {
            try? KeychainManager.shared.deleteOpenCodeAPIKey(providerID: providerID, serverID: targetServer.id)
        }
    }

    func useLegacyAPIKeyForOpenCode() {
        do {
            let legacyProvider = try AIProviderCredentialMigration.copyLegacyAPIKeyForOpenCode(
                providerID: profile.normalizedProviderID
            )
            statusMessage = "Copied the existing \(legacyProvider.displayName) API key for OpenCode."
        } catch {
            present(error)
        }
    }

    func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
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
