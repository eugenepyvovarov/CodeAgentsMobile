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
    @State var showChangeSheet = false
    @State var changePath = NavigationPath()
    @State var changeProviderSearchText = ""
    @State var changeModelSearchText = ""
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
    @State var isStartingOAuth = false
    @State var isCompletingOAuth = false
    @State var oauthAuthorization: OpenCodeProviderOAuthAuthorization?
    @State var oauthMethodIndex: Int?
    @State var oauthCode = ""
    @State var oauthPromptInputs: [String: String] = [:]
    @State var copiedOAuthConfirmationCode = false
    @State var oauthCompletedServerID: UUID?
    @State var oauthCompletedProviderID: String?

    let settingsStore = OpenCodeAIProviderSettingsStore()

    init(server: Server? = nil, navigationTitle: String? = nil) {
        self.server = server
        self.navigationTitle = navigationTitle
    }

    var body: some View {
        List {
            scopeSection
            currentSetupSection
            homeStatusSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(navigationTitle ?? (server == nil ? "OpenCode AI" : "Server AI"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { homeToolbarContent }
        .onAppear {
            loadSettings()
            loadCachedProviderStatusIfPossible()
            Task { await refreshProviderStatusIfPossible() }
        }
        .onChange(of: servers.map(\.id)) { _, _ in
            // @Query may settle after first appear; hydrate cache once servers exist.
            if providerStatus == nil {
                loadCachedProviderStatusIfPossible()
            }
        }
        .onChange(of: useGlobalDefaults) { _, newValue in
            loadServerScope(useGlobalDefaults: newValue)
        }
        .sheet(isPresented: $showChangeSheet) {
            changeSetupSheet
                .onAppear {
                    changeProviderSearchText = ""
                    changeModelSearchText = ""
                    changePath = NavigationPath()
                }
        }
        .confirmationDialog(
            removeAuthFromAllServers
                ? "Disconnect \(selectedProviderName) from every server?"
                : "Disconnect \(selectedProviderName) from \(authActionTargetServer?.name ?? "this server")?",
            isPresented: $confirmRemoveAuth,
            titleVisibility: .visible
        ) {
            Button(
                removeAuthFromAllServers ? "Disconnect on All Servers" : "Disconnect",
                role: .destructive
            ) {
                Task { await removeSelectedProviderAuth() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected provider credential from OpenCode. You can reconnect it from Change… immediately after.")
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
                resetOAuthState()
                if newValue != .oauth {
                    clearOAuthCompletionIfProviderMismatch()
                }
                if newValue == .oauth {
                    customProviderEnabled = false
                    apiKey = ""
                    seedOAuthPromptDefaults()
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
            let hasAuth = providerStatus?.isAuthenticated(providerID: provider.id) == true
                || providerStatus?.connectedProviderIDs.contains(where: {
                    $0.caseInsensitiveCompare(provider.id) == .orderedSame
                }) == true
            append(OpenCodeProviderChoice(
                id: provider.id,
                name: provider.name,
                subtitle: hasAuth
                    ? authorizedProviderSubtitle(
                        providerID: provider.id,
                        modelCount: provider.models.count
                    )
                    : (provider.models.isEmpty ? "Provider from OpenCode" : "\(provider.models.count) models available"),
                systemImage: OpenCodeProviderPreset.symbol(for: provider.id),
                isCustom: false,
                isConnected: hasAuth,
                supportsOAuth: providerStatus?.supportsOAuth(for: provider.id) == true
                    || OpenCodeProviderPreset.supportsOAuth(for: provider.id)
            ))
        }

        for preset in OpenCodeProviderPreset.preferred {
            let hasAuth = providerStatus?.isAuthenticated(providerID: preset.id) == true
                || providerStatus?.connectedProviderIDs.contains(where: {
                    $0.caseInsensitiveCompare(preset.id) == .orderedSame
                }) == true
            let supportsOAuth = providerStatus?.supportsOAuth(for: preset.id) == true || preset.supportsOAuth
            append(OpenCodeProviderChoice(
                id: preset.id,
                name: preset.name,
                subtitle: hasAuth
                    ? authorizedProviderSubtitle(providerID: preset.id, fallback: preset.subtitle)
                    : preset.subtitle,
                systemImage: preset.systemImage,
                isCustom: false,
                isConnected: hasAuth,
                supportsOAuth: supportsOAuth
            ))
        }

        append(OpenCodeProviderChoice(
            id: "other",
            name: "Other",
            subtitle: "OpenAI-compatible endpoint",
            systemImage: "plus.circle",
            isCustom: true,
            isConnected: false,
            supportsOAuth: false
        ))

        return choices
    }

    /// Subtitle for authorized providers in the picker (shows exact server auth type).
    func authorizedProviderSubtitle(
        providerID: String,
        modelCount: Int? = nil,
        fallback: String? = nil
    ) -> String {
        let authLabel: String
        if let raw = providerStatus?.authenticatedAuthType(for: providerID) {
            switch raw {
            case "api", "api_key", "apikey", "key":
                authLabel = "API Key"
            case "oauth", "openai", "chatgpt":
                authLabel = OpenCodeProviderPreset.oauthDisplayName(
                    providerID: providerID,
                    methodLabel: preferredOAuthMethodLabel(for: providerID)
                )
            case "unknown", "":
                authLabel = "Authorized"
            default:
                authLabel = raw.replacingOccurrences(of: "_", with: " ").capitalized
            }
        } else {
            authLabel = "Authorized"
        }

        var parts = [authLabel]
        if let modelCount {
            if modelCount == 0 {
                parts.append("on server")
            } else {
                parts.append("\(modelCount) models")
            }
        } else if let fallback, !fallback.isEmpty {
            parts.append(fallback)
        }
        return parts.joined(separator: " · ")
    }

    var selectedProviderModelChoices: [OpenCodeModelChoice] {
        guard !profile.normalizedProviderID.isEmpty else { return [] }
        return providerStatus?.modelChoices(for: profile.normalizedProviderID) ?? []
    }

    var selectedModelChoice: OpenCodeModelChoice? {
        guard let modelID = profile.resolvedModelID else { return nil }
        return selectedProviderModelChoices.first {
            $0.id.caseInsensitiveCompare(modelID) == .orderedSame
        }
    }

    var thinkingChoices: [OpenCodeThinkingChoice] {
        if let selectedModelChoice {
            return OpenCodeThinkingSupport.choices(
                for: selectedModelChoice,
                providerID: profile.normalizedProviderID
            )
        }
        return OpenCodeThinkingSupport.fallbackChoices(
            providerID: profile.normalizedProviderID,
            supportsReasoning: false
        )
    }

    var showsThinkingSection: Bool {
        !customProviderEnabled && (selectedModelChoice?.supportsReasoning == true || thinkingChoices.count > 1)
    }

    var selectedThinkingTitle: String {
        let current = profile.variant.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = thinkingChoices.first(where: { $0.id.caseInsensitiveCompare(current) == .orderedSame }) {
            return match.title
        }
        return OpenCodeThinkingChoice.automatic.title
    }

    var selectedThinkingSubtitle: String {
        let current = profile.variant.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = thinkingChoices.first(where: { $0.id.caseInsensitiveCompare(current) == .orderedSame }),
           let subtitle = match.subtitle {
            return subtitle
        }
        if current.isEmpty {
            return "\(thinkingChoices.count - 1) level\(thinkingChoices.count == 2 ? "" : "s") available"
        }
        return OpenCodeThinkingSupport.displayTitle(for: current)
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
            let base = profile.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty {
                return "Custom · OpenAI-compatible endpoint"
            }
            return "Custom · \(base)"
        }
        return "\(selectedConnectionMethodTitle) · \(selectedConnectionStatusTitle)"
    }

    /// Human-readable auth method for the selected provider (what you configure in the app).
    var selectedConnectionMethodTitle: String {
        if customProviderEnabled {
            return "Custom endpoint"
        }
        if selectedProviderUsesNoCredential {
            return "No API key"
        }
        if profile.authMode == .oauth {
            return selectedOAuthMethodTitle
        }
        return "API Key"
    }

    /// Server-side connection state, including the exact auth type when known.
    var selectedConnectionStatusTitle: String {
        if selectedProviderUsesNoCredential {
            return "Ready (bundled)"
        }

        let serverLabel = statusSourceName?
            .replacingOccurrences(of: " (cached)", with: "")
            ?? authActionTargetServer?.name
            ?? "server"

        if providerConnectedInStatus {
            if let serverAuthLabel = serverAuthTypeDisplayLabel {
                return "Connected on \(serverLabel) via \(serverAuthLabel)"
            }
            return "Connected on \(serverLabel)"
        }

        if oauthCompletedForTargetServer {
            return "Login finished on \(serverLabel)"
        }

        return "Not connected on \(serverLabel)"
    }

    /// Prefer live auth.json type; fall back to the profile's chosen mode.
    var serverAuthTypeDisplayLabel: String? {
        let providerID = profile.normalizedProviderID
        if let raw = providerStatus?.authenticatedAuthType(for: providerID) {
            switch raw {
            case "api", "api_key", "apikey", "key":
                return "API Key"
            case "oauth", "openai", "chatgpt":
                return OpenCodeProviderPreset.oauthDisplayName(
                    providerID: providerID,
                    methodLabel: preferredOAuthMethodLabel(for: providerID)
                )
            case "unknown", "":
                break
            default:
                return raw.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }

        if profile.authMode == .oauth {
            return selectedOAuthMethodTitle
        }
        if profile.requiresAPIKeyCredential {
            return "API Key"
        }
        return nil
    }

    var selectedOAuthMethodTitle: String {
        if let selected = selectedOAuthMethod {
            return OpenCodeProviderPreset.oauthDisplayName(
                providerID: profile.normalizedProviderID,
                methodLabel: selected.method.shortDisplayLabel
            )
        }
        return OpenCodeProviderPreset.oauthDisplayName(
            providerID: profile.normalizedProviderID,
            methodLabel: nil
        )
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
              let choice = selectedProviderModelChoices.first(where: { $0.id.caseInsensitiveCompare(modelID) == .orderedSame }) else {
            return countText
        }
        var parts: [String] = []
        if choice.modelName.caseInsensitiveCompare(choice.modelID) != .orderedSame {
            parts.append(choice.modelName)
        }
        parts.append(countText)
        if choice.supportsReasoning {
            parts.append("supports thinking")
        }
        return parts.joined(separator: " · ")
    }

    /// True when this provider can use OAuth/subscription login (server methods or known plugins).
    var supportsOAuthAuth: Bool {
        guard !customProviderEnabled else { return false }
        if providerStatus?.supportsOAuth(for: profile.normalizedProviderID) == true {
            return true
        }
        // Catalog not loaded yet — still allow known subscription providers.
        return OpenCodeProviderPreset.supportsOAuth(for: profile.normalizedProviderID)
    }

    var supportsAPIKeyAuth: Bool {
        guard !customProviderEnabled else { return true }
        if selectedProviderUsesNoCredential { return false }
        if let status = providerStatus {
            // When methods are known, honor them. If the provider only reports OAuth, hide API key.
            let methods = status.authMethods(for: profile.normalizedProviderID)
            if !methods.isEmpty {
                return status.supportsAPIKey(for: profile.normalizedProviderID)
            }
        }
        // Unknown methods: most providers accept an API key; pure-OAuth-only known set is small.
        switch profile.normalizedProviderID {
        case "github-copilot":
            return false
        default:
            return true
        }
    }

    var showsAuthModePicker: Bool {
        supportsOAuthAuth && supportsAPIKeyAuth
    }

    var selectedProviderUsesNoCredential: Bool {
        // OpenCode Zen models are available without a provider key; Console OAuth is optional.
        profile.normalizedProviderID == "opencode"
            && !customProviderEnabled
            && profile.authMode != .oauth
    }

    var providerIsConnected: Bool {
        providerConnectedInStatus || oauthCompletedForTargetServer
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

    var oauthCompletedForTargetServer: Bool {
        guard profile.authMode == .oauth,
              let completedProvider = oauthCompletedProviderID,
              completedProvider.caseInsensitiveCompare(profile.normalizedProviderID) == .orderedSame,
              let targetServer = oauthTargetServer else {
            return false
        }
        return oauthCompletedServerID == targetServer.id
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
        return "OAuth runs on the OpenCode server (device code preferred for remote hosts). CodeAgents only shows the link and code; credentials stay in the server auth store."
    }

    var authActionTargetServer: Server? {
        server ?? servers.first
    }

    var oauthTargetServer: Server? {
        server ?? servers.first
    }

    var availableOAuthMethods: [(index: Int, method: OpenCodeProviderAuthMethod)] {
        providerStatus?.oauthMethods(for: profile.normalizedProviderID) ?? []
    }

    var selectedOAuthMethod: (index: Int, method: OpenCodeProviderAuthMethod)? {
        if let oauthMethodIndex,
           let match = availableOAuthMethods.first(where: { $0.index == oauthMethodIndex }) {
            return match
        }
        return providerStatus?.preferredOAuthMethod(for: profile.normalizedProviderID)
            ?? availableOAuthMethods.first
    }

    var selectedOAuthPrompts: [OpenCodeProviderAuthPrompt] {
        selectedOAuthMethod?.method.prompts ?? []
    }

    func preferredOAuthMethodLabel(for providerID: String) -> String? {
        providerStatus?.preferredOAuthMethod(for: providerID)?.method.shortDisplayLabel
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

    func copyOAuthConfirmationCode(_ code: String) {
        UIPasteboard.general.string = code
        copiedOAuthConfirmationCode = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copiedOAuthConfirmationCode = false
        }
    }

    func oauthConfirmationCode(from instructions: String) -> String? {
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let range = trimmed.range(of: "code:", options: [.caseInsensitive]) {
            let suffix = trimmed[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return suffix.isEmpty ? nil : suffix
        }
        // Some flows put only the user code in instructions.
        let token = trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init)
        if let token, token.count >= 4, token.count <= 24, token.contains(where: { $0.isLetter || $0.isNumber }) {
            return token
        }
        return nil
    }

    func resetOAuthState() {
        oauthAuthorization = nil
        oauthMethodIndex = nil
        oauthCode = ""
        oauthPromptInputs = [:]
        copiedOAuthConfirmationCode = false
    }

    func clearOAuthCompletionIfProviderMismatch() {
        if let completed = oauthCompletedProviderID,
           completed.caseInsensitiveCompare(profile.normalizedProviderID) != .orderedSame {
            oauthCompletedServerID = nil
            oauthCompletedProviderID = nil
        }
        if profile.authMode != .oauth {
            oauthCompletedServerID = nil
            oauthCompletedProviderID = nil
        }
    }

    func seedOAuthPromptDefaults() {
        guard let method = selectedOAuthMethod?.method else { return }
        var inputs = oauthPromptInputs
        for prompt in method.prompts ?? [] {
            if inputs[prompt.key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                if let first = prompt.options?.first?.value {
                    inputs[prompt.key] = first
                } else if let placeholder = prompt.placeholder, !placeholder.isEmpty {
                    inputs[prompt.key] = placeholder
                } else if prompt.key == "instanceUrl" {
                    inputs[prompt.key] = "https://gitlab.com"
                } else if prompt.key == "deploymentType" {
                    inputs[prompt.key] = "github.com"
                }
            }
        }
        oauthPromptInputs = inputs
        if oauthMethodIndex == nil, let index = selectedOAuthMethod?.index {
            oauthMethodIndex = index
        }
    }

    func oauthPromptInputsReady(for method: OpenCodeProviderAuthMethod) -> Bool {
        for prompt in method.prompts ?? [] {
            let value = oauthPromptInputs[prompt.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if value.isEmpty {
                // Optional only when placeholder suggests a default we'll send.
                if let placeholder = prompt.placeholder, !placeholder.isEmpty {
                    continue
                }
                if prompt.key == "instanceUrl" || prompt.key == "deploymentType" {
                    continue
                }
                return false
            }
        }
        return true
    }

    func resolvedOAuthInputs(for method: OpenCodeProviderAuthMethod) -> [String: String] {
        var inputs: [String: String] = [:]
        for prompt in method.prompts ?? [] {
            var value = oauthPromptInputs[prompt.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if value.isEmpty {
                if let placeholder = prompt.placeholder, !placeholder.isEmpty {
                    value = placeholder
                } else if prompt.key == "instanceUrl" {
                    value = "https://gitlab.com"
                } else if prompt.key == "deploymentType" {
                    value = prompt.options?.first?.value ?? "github.com"
                }
            }
            if !value.isEmpty {
                inputs[prompt.key] = value
            }
        }
        return inputs
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
        resetOAuthState()
        seedOAuthPromptDefaults()
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
        resetOAuthState()
        seedOAuthPromptDefaults()
        repairSelectedModelIfNeeded()
    }

    func selectProvider(_ choice: OpenCodeProviderChoice) {
        let didChangeProvider = choice.id.caseInsensitiveCompare(profile.normalizedProviderID) != .orderedSame
        resetOAuthState()
        if didChangeProvider || choice.isCustom || !choice.supportsOAuth {
            oauthCompletedServerID = nil
            oauthCompletedProviderID = nil
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
            profile.variant = ""
        } else {
            customProviderEnabled = false
            profile.providerID = choice.id
            profile.providerName = choice.name
            profile.customBaseURL = ""
            profile.customModelID = ""
            profile.customModelName = ""
            if didChangeProvider {
                profile.authMode = preferredAuthMode(for: choice)
                profile.modelID = ""
                profile.smallModelID = ""
                profile.variant = ""
            } else if profile.authMode == .oauth && !choice.supportsOAuth {
                profile.authMode = .apiKey
            } else if profile.authMode == .apiKey && !supportsAPIKeyAuth && choice.supportsOAuth {
                profile.authMode = .oauth
            }
            if profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.modelID = OpenCodeProviderConnectionDefaults.suggestedModelID(
                    providerID: choice.id,
                    status: providerStatus
                ) ?? ""
            }
            if profile.authMode == .oauth {
                seedOAuthPromptDefaults()
            }
        }
        repairSelectedModelIfNeeded()
        repairSelectedThinkingIfNeeded()
        apiKey = ""
    }

    func preferredAuthMode(for choice: OpenCodeProviderChoice) -> OpenCodeProviderAuthMode {
        let providerID = choice.id
        let hasOAuth = choice.supportsOAuth
            || providerStatus?.supportsOAuth(for: providerID) == true
        let hasAPIKey: Bool = {
            if let status = providerStatus {
                let methods = status.authMethods(for: providerID)
                if !methods.isEmpty {
                    return status.supportsAPIKey(for: providerID)
                }
            }
            return providerID.caseInsensitiveCompare("github-copilot") != .orderedSame
        }()

        if hasOAuth {
            if let preferred = providerStatus?.preferredOAuthMethod(for: providerID),
               preferred.method.isHeadlessPreferred {
                return .oauth
            }
            // Known subscription providers default to OAuth when available.
            if OpenCodeProviderPreset.supportsOAuth(for: providerID) && !hasAPIKey {
                return .oauth
            }
            if OpenCodeProviderPreset.supportsOAuth(for: providerID),
               ["openai", "xai", "github-copilot", "gitlab", "digitalocean"].contains(where: {
                   $0.caseInsensitiveCompare(providerID) == .orderedSame
               }) {
                return .oauth
            }
        }
        if hasAPIKey {
            return .apiKey
        }
        return hasOAuth ? .oauth : .apiKey
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
        if !choice.supportsReasoning {
            profile.variant = ""
        } else {
            repairSelectedThinkingIfNeeded(for: choice)
        }
    }

    func selectThinking(_ choice: OpenCodeThinkingChoice) {
        profile.variant = choice.id
    }

    func repairSelectedThinkingIfNeeded(for model: OpenCodeModelChoice? = nil) {
        if customProviderEnabled {
            profile.variant = ""
            return
        }

        let target = model ?? selectedModelChoice
        guard let target else {
            // Free-text model path or no selection yet — keep stored variant.
            return
        }

        if !target.supportsReasoning {
            profile.variant = ""
            return
        }

        let current = profile.variant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return }

        let validIDs = OpenCodeThinkingSupport.choices(
            for: target,
            providerID: profile.normalizedProviderID
        )
        let isValid = validIDs.contains {
            $0.id.caseInsensitiveCompare(current) == .orderedSame
        }
        if !isValid {
            profile.variant = ""
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
    func startProviderOAuth() async {
        guard let targetServer = oauthTargetServer,
              let oauthMethod = selectedOAuthMethod else {
            return
        }

        guard oauthPromptInputsReady(for: oauthMethod.method) else {
            present(OpenCodeProviderServiceError.invalidInput)
            return
        }

        isStartingOAuth = true
        defer { isStartingOAuth = false }

        do {
            oauthCompletedServerID = nil
            oauthCompletedProviderID = nil
            let inputs = resolvedOAuthInputs(for: oauthMethod.method)
            let authorization = try await providerService.startOAuth(
                providerID: profile.normalizedProviderID,
                methodIndex: oauthMethod.index,
                inputs: inputs,
                on: targetServer
            )
            oauthAuthorization = authorization
            oauthMethodIndex = oauthMethod.index
            oauthCode = ""
            let name = selectedProviderName
            statusMessage = "Open the login link, finish \(name) authorization, then return here."
        } catch {
            present(error)
        }
    }

    @MainActor
    func completeProviderOAuth() async {
        guard let targetServer = oauthTargetServer,
              let methodIndex = oauthMethodIndex ?? selectedOAuthMethod?.index,
              let authorization = oauthAuthorization else {
            return
        }

        let code = authorization.isCodeBased ? oauthCode.trimmedOpenCodeValue : nil
        if authorization.isCodeBased, code?.isEmpty != false {
            present(OpenCodeProviderServiceError.invalidInput)
            return
        }

        isCompletingOAuth = true
        defer { isCompletingOAuth = false }

        do {
            try await providerService.completeOAuth(
                providerID: profile.normalizedProviderID,
                methodIndex: methodIndex,
                code: code,
                on: targetServer
            )
            oauthCompletedServerID = targetServer.id
            oauthCompletedProviderID = profile.normalizedProviderID
            resetOAuthState()
            statusMessage = "\(selectedProviderName) connected on \(targetServer.name)."
            await refreshProviderStatusIfPossible()
        } catch {
            present(error)
        }
    }

    /// Paint last known OpenCode catalog immediately (avoids preset-list flash).
    func loadCachedProviderStatusIfPossible() {
        let targetServer = server ?? servers.first
        guard let targetServer else { return }
        guard providerStatus == nil else { return }
        guard let cached = providerService.cachedStatus(for: targetServer.id) else { return }

        providerStatus = cached.status
        statusSourceName = "\(cached.serverName) (cached)"
        repairSelectedModelIfNeeded()
        repairSelectedThinkingIfNeeded()
        clearAutoFilledSmallModelOverrideIfNeeded()
    }

    @MainActor
    func refreshProviderStatusIfPossible() async {
        let targetServer = server ?? servers.first
        guard let targetServer else { return }

        // Prefer disk/memory cache if state was empty when the view appeared
        // before servers query settled.
        if providerStatus == nil {
            loadCachedProviderStatusIfPossible()
        }

        isRefreshingStatus = true
        defer { isRefreshingStatus = false }

        do {
            providerStatus = try await providerService.status(for: targetServer)
            statusSourceName = targetServer.name
            repairSelectedModelIfNeeded()
            repairSelectedThinkingIfNeeded()
            clearAutoFilledSmallModelOverrideIfNeeded()
            clearOAuthCompletionIfProviderMismatch()
            if profile.authMode == .oauth {
                seedOAuthPromptDefaults()
            }
        } catch {
            if providerStatus == nil {
                statusMessage = "Provider list unavailable. You can still connect a provider manually."
            } else {
                statusMessage = "Using cached provider list. Live refresh failed."
            }
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

    /// Applies the in-progress Change selection to the relevant server(s).
    /// - Returns: `true` when OpenCode accepted the profile (sheet may dismiss).
    @MainActor
    @discardableResult
    func applyCurrentSelection() async -> Bool {
        guard canApply else { return false }
        if server == nil, servers.isEmpty {
            present(OpenCodeProviderServiceError.invalidInput)
            return false
        }

        isApplying = true
        defer { isApplying = false }

        do {
            let normalized = try persistSelection()
            let apiKeyToApply = apiKey.trimmedOpenCodeValue.nilIfEmpty
            let profileToApply: OpenCodeAIProviderProfile
            if let targetServer = server {
                profileToApply = useGlobalDefaults
                    ? settingsStore.globalProfile()
                    : normalized
                try await providerService.applyAIProviderProfile(
                    profileToApply,
                    apiKey: apiKeyToApply,
                    to: targetServer
                )
                apiKey = ""
                statusMessage = "Saved on \(targetServer.name)."
            } else {
                profileToApply = normalized
                for targetServer in servers {
                    try await providerService.applyAIProviderProfile(
                        profileToApply,
                        apiKey: apiKeyToApply,
                        to: targetServer
                    )
                }
                apiKey = ""
                let count = servers.count
                statusMessage = "Saved on \(count) server\(count == 1 ? "" : "s")."
            }

            await refreshProviderStatusIfPossible()
            return true
        } catch {
            present(error)
            return false
        }
    }

    /// Final Change-sheet action: write OpenCode config, then close the wizard.
    @MainActor
    func finishChangeAndApply() async {
        let succeeded = await applyCurrentSelection()
        if succeeded {
            showChangeSheet = false
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
            oauthCompletedServerID = nil
            oauthCompletedProviderID = nil
            resetOAuthState()
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
