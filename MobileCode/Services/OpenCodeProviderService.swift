//
//  OpenCodeProviderService.swift
//  CodeAgentsMobile
//
//  Purpose: OpenCode provider/auth status and server-side credential apply
//

import Foundation

struct OpenCodeProviderStatus: Codable, Equatable {
    let providers: [OpenCodeProvider]
    let configuredProviders: [OpenCodeProvider]
    let defaultModels: [String: String]
    let connectedProviderIDs: [String]
    let authenticatedProviderIDs: [String]
    /// Raw auth type from OpenCode `auth.json` when known (`api`, `oauth`, …), keyed by provider id.
    let authenticatedAuthTypes: [String: String]
    let authMethods: [String: [OpenCodeProviderAuthMethod]]

    init(
        providers: [OpenCodeProvider],
        configuredProviders: [OpenCodeProvider] = [],
        defaultModels: [String: String],
        connectedProviderIDs: [String],
        authenticatedProviderIDs: [String] = [],
        authenticatedAuthTypes: [String: String] = [:],
        authMethods: [String: [OpenCodeProviderAuthMethod]]
    ) {
        self.providers = providers
        self.configuredProviders = configuredProviders
        self.defaultModels = defaultModels
        self.connectedProviderIDs = connectedProviderIDs
        self.authenticatedProviderIDs = authenticatedProviderIDs
        self.authenticatedAuthTypes = authenticatedAuthTypes
        self.authMethods = authMethods
    }

    enum CodingKeys: String, CodingKey {
        case providers, configuredProviders, defaultModels
        case connectedProviderIDs, authenticatedProviderIDs, authenticatedAuthTypes, authMethods
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = try container.decode([OpenCodeProvider].self, forKey: .providers)
        configuredProviders = try container.decodeIfPresent([OpenCodeProvider].self, forKey: .configuredProviders) ?? []
        defaultModels = try container.decodeIfPresent([String: String].self, forKey: .defaultModels) ?? [:]
        connectedProviderIDs = try container.decodeIfPresent([String].self, forKey: .connectedProviderIDs) ?? []
        authenticatedProviderIDs = try container.decodeIfPresent([String].self, forKey: .authenticatedProviderIDs) ?? []
        authenticatedAuthTypes = try container.decodeIfPresent([String: String].self, forKey: .authenticatedAuthTypes) ?? [:]
        authMethods = try container.decodeIfPresent([String: [OpenCodeProviderAuthMethod]].self, forKey: .authMethods) ?? [:]
    }

    func isAuthenticated(providerID: String) -> Bool {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProviderID.isEmpty else { return false }
        return authenticatedProviderIDs.contains {
            $0.caseInsensitiveCompare(normalizedProviderID) == .orderedSame
        }
    }

    /// Server-side auth type for a provider (`api`, `oauth`, …), if recorded in auth.json.
    func authenticatedAuthType(for providerID: String) -> String? {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProviderID.isEmpty else { return nil }
        if let exact = authenticatedAuthTypes[normalizedProviderID] {
            return exact
        }
        return authenticatedAuthTypes.first(where: {
            $0.key.caseInsensitiveCompare(normalizedProviderID) == .orderedSame
        })?.value
    }

    var apiKeyProviders: [OpenCodeProvider] {
        providers.filter { provider in
            authMethods[provider.id]?.contains(where: { $0.isAPIKeyBased }) == true
        }
    }

    var apiKeyProviderChoices: [OpenCodeAPIKeyProviderChoice] {
        let discovered = apiKeyProviders.map { provider in
            OpenCodeAPIKeyProviderChoice(id: provider.id, name: provider.name)
        }
        return OpenCodeAPIKeyProviderChoice.merging(discovered, with: OpenCodeAPIKeyProviderChoice.preferred)
    }

    var modelChoices: [OpenCodeModelChoice] {
        providers.flatMap { provider in
            modelChoices(from: provider)
        }
        .sorted { lhs, rhs in
            lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }
    }

    func authMethods(for providerID: String) -> [OpenCodeProviderAuthMethod] {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProviderID.isEmpty else { return [] }
        if let exact = authMethods[normalizedProviderID] {
            return exact
        }
        return authMethods.first(where: {
            $0.key.caseInsensitiveCompare(normalizedProviderID) == .orderedSame
        })?.value ?? []
    }

    func oauthMethods(for providerID: String) -> [(index: Int, method: OpenCodeProviderAuthMethod)] {
        authMethods(for: providerID).enumerated().compactMap { index, method in
            method.isOAuthBased ? (index, method) : nil
        }
    }

    func preferredOAuthMethod(for providerID: String) -> (index: Int, method: OpenCodeProviderAuthMethod)? {
        OpenCodeProviderOAuthMethodSelection.preferred(in: authMethods(for: providerID))
    }

    func supportsOAuth(for providerID: String) -> Bool {
        !oauthMethods(for: providerID).isEmpty
    }

    func supportsAPIKey(for providerID: String) -> Bool {
        authMethods(for: providerID).contains(where: \.isAPIKeyBased)
    }

    func modelChoices(for providerID: String) -> [OpenCodeModelChoice] {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProviderID.isEmpty else { return [] }

        // Prefer OpenCode's live catalog (`/provider`). Configured provider.models from
        // opencode.json can include free-text / stale ids that are not real provider models.
        // Only fall back to configured models when the catalog has nothing for this provider
        // (custom OpenAI-compatible endpoints, empty catalog, etc.).
        if let catalogProvider = providers.first(where: { provider in
            provider.id.caseInsensitiveCompare(normalizedProviderID) == .orderedSame
        }), !catalogProvider.models.isEmpty {
            return modelChoices(from: catalogProvider)
        }

        if let configuredProvider = configuredProviders.first(where: { provider in
            provider.id.caseInsensitiveCompare(normalizedProviderID) == .orderedSame
        }), !configuredProvider.models.isEmpty {
            return modelChoices(from: configuredProvider)
        }

        return []
    }

    func hasModel(providerID: String, modelID: String) -> Bool {
        modelChoice(for: providerID, modelID: modelID) != nil
    }

    /// Resolve a stored model id that may be either bare (`gpt-5.5`) or full (`openai/gpt-5.5`).
    func modelChoice(for providerID: String, modelID: String) -> OpenCodeModelChoice? {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return modelChoices(for: providerID).first { $0.matches(storedModelID: trimmed) }
    }

    private func modelChoices(from provider: OpenCodeProvider) -> [OpenCodeModelChoice] {
        provider.models.values
            .filter(\.isChatCapable)
            .map { model in
                OpenCodeModelChoice(
                    providerID: provider.id,
                    providerName: provider.name,
                    modelID: model.id,
                    modelName: model.name,
                    supportsReasoning: model.supportsReasoning,
                    effortLevels: model.effortLevels,
                    isDeprecated: model.isDeprecated
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDeprecated != rhs.isDeprecated {
                    return !lhs.isDeprecated && rhs.isDeprecated
                }
                let nameOrder = lhs.modelName.localizedCaseInsensitiveCompare(rhs.modelName)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }
    }

    func thinkingChoices(for providerID: String, modelID: String) -> [OpenCodeThinkingChoice] {
        if let match = modelChoice(for: providerID, modelID: modelID) {
            return OpenCodeThinkingSupport.choices(for: match, providerID: providerID)
        }
        return OpenCodeThinkingSupport.fallbackChoices(providerID: providerID, supportsReasoning: false)
    }
}

struct OpenCodeAPIKeyProviderChoice: Identifiable, Hashable {
    let id: String
    let name: String

    static let preferred: [OpenCodeAPIKeyProviderChoice] = [
        OpenCodeAPIKeyProviderChoice(id: "anthropic", name: "Anthropic"),
        OpenCodeAPIKeyProviderChoice(id: "openai", name: "OpenAI"),
        OpenCodeAPIKeyProviderChoice(id: "google", name: "Google"),
        OpenCodeAPIKeyProviderChoice(id: "xai", name: "xAI"),
        OpenCodeAPIKeyProviderChoice(id: "groq", name: "Groq"),
        OpenCodeAPIKeyProviderChoice(id: "openrouter", name: "OpenRouter"),
        OpenCodeAPIKeyProviderChoice(id: "minimax", name: "MiniMax")
    ]

    static func merging(
        _ discovered: [OpenCodeAPIKeyProviderChoice],
        with preferred: [OpenCodeAPIKeyProviderChoice]
    ) -> [OpenCodeAPIKeyProviderChoice] {
        var seen = Set<String>()
        var merged: [OpenCodeAPIKeyProviderChoice] = []

        for choice in discovered + preferred {
            let normalizedID = choice.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedID.isEmpty, !seen.contains(normalizedID) else { continue }
            seen.insert(normalizedID)
            merged.append(choice)
        }

        return merged
    }
}

enum OpenCodeProviderConnectionDefaults {
    static func suggestedModelID(providerID: String, status: OpenCodeProviderStatus?) -> String? {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProviderID.isEmpty else { return nil }

        if let defaultModel = status?.defaultModels.first(where: { key, _ in
            key.caseInsensitiveCompare(normalizedProviderID) == .orderedSame
        })?.value.nilIfEmpty {
            let availableChoices = status?.modelChoices(for: normalizedProviderID) ?? []
            if !availableChoices.isEmpty,
               status?.hasModel(providerID: normalizedProviderID, modelID: defaultModel) == false {
                return nil
            }
            return "\(normalizedProviderID)/\(defaultModel)"
        }

        switch normalizedProviderID.lowercased() {
        case "minimax":
            return "minimax/MiniMax-M2.7"
        default:
            return nil
        }
    }

    static func suggestedSmallModelID(providerID: String, status: OpenCodeProviderStatus?) -> String? {
        suggestedModelID(providerID: providerID, status: status)
    }
}

struct OpenCodeModelChoice: Identifiable, Hashable {
    let providerID: String
    let providerName: String
    let modelID: String
    let modelName: String
    let supportsReasoning: Bool
    let effortLevels: [String]
    let isDeprecated: Bool

    init(
        providerID: String,
        providerName: String,
        modelID: String,
        modelName: String,
        supportsReasoning: Bool = false,
        effortLevels: [String] = [],
        isDeprecated: Bool = false
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.modelID = modelID
        self.modelName = modelName
        self.supportsReasoning = supportsReasoning
        self.effortLevels = effortLevels
        self.isDeprecated = isDeprecated
    }

    var id: String {
        "\(providerID)/\(modelID)"
    }

    var label: String {
        "\(providerName) · \(modelName)"
    }

    /// Match stored profile values that may be bare model ids or `provider/model` composites.
    func matches(storedModelID: String) -> Bool {
        let trimmed = storedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if id.caseInsensitiveCompare(trimmed) == .orderedSame {
            return true
        }
        if modelID.caseInsensitiveCompare(trimmed) == .orderedSame {
            return true
        }
        if let parsed = OpenCodePromptModel(fullID: trimmed) {
            return parsed.providerID.caseInsensitiveCompare(providerID) == .orderedSame
                && parsed.modelID.caseInsensitiveCompare(modelID) == .orderedSame
        }
        return false
    }
}

/// UI option for OpenCode thinking / reasoning effort (maps to variants + model options).
struct OpenCodeThinkingChoice: Identifiable, Hashable {
    /// Empty id means OpenCode default (omit variant/options).
    let id: String
    let title: String
    let subtitle: String?

    static let automatic = OpenCodeThinkingChoice(
        id: "",
        title: "Default",
        subtitle: "Use OpenCode model default"
    )
}

enum OpenCodeThinkingSupport {
    /// Build thinking choices for a model, falling back to provider family defaults when needed.
    static func choices(for model: OpenCodeModelChoice, providerID: String) -> [OpenCodeThinkingChoice] {
        var result: [OpenCodeThinkingChoice] = [.automatic]
        var seen = Set<String>([""])

        let levels: [String]
        if !model.effortLevels.isEmpty {
            levels = model.effortLevels
        } else if model.supportsReasoning {
            levels = fallbackEffortKeys(providerID: providerID)
        } else {
            return result
        }

        for raw in levels {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = key.lowercased()
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            result.append(OpenCodeThinkingChoice(
                id: key,
                title: displayTitle(for: key),
                subtitle: displaySubtitle(for: key)
            ))
        }
        return result
    }

    static func fallbackChoices(providerID: String, supportsReasoning: Bool) -> [OpenCodeThinkingChoice] {
        guard supportsReasoning else { return [.automatic] }
        let synthetic = OpenCodeModelChoice(
            providerID: providerID,
            providerName: providerID,
            modelID: "",
            modelName: "",
            supportsReasoning: true,
            effortLevels: fallbackEffortKeys(providerID: providerID)
        )
        return choices(for: synthetic, providerID: providerID)
    }

    static func displayTitle(for effort: String) -> String {
        switch effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "auto", "default":
            return "Default"
        case "none", "off":
            return "Off"
        case "minimal":
            return "Minimal"
        case "low":
            return "Low"
        case "medium":
            return "Medium"
        case "high":
            return "High"
        case "xhigh", "extra-high", "extra_high":
            return "Extra High"
        case "max", "maximum":
            return "Max"
        default:
            return effort.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func displaySubtitle(for effort: String) -> String? {
        switch effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none", "off":
            return "Disable extended thinking when supported"
        case "minimal", "low":
            return "Faster, lighter reasoning"
        case "medium":
            return "Balanced reasoning"
        case "high":
            return "Deeper reasoning"
        case "xhigh", "max", "maximum":
            return "Maximum thinking budget"
        default:
            return nil
        }
    }

    /// Provider-family fallbacks when the API omits `reasoning_options` / variants.
    static func fallbackEffortKeys(providerID: String) -> [String] {
        switch providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "anthropic", "opencode":
            return ["high", "max"]
        case "openai", "azure", "azure-cognitive-services":
            return ["none", "minimal", "low", "medium", "high", "xhigh"]
        case "google", "google-vertex":
            return ["low", "high"]
        case "xai":
            return ["low", "medium", "high", "xhigh"]
        default:
            return ["low", "medium", "high"]
        }
    }

    /// Map a selected thinking level into OpenCode model `options` for opencode.json.
    static func modelOptions(variant: String, providerID: String) -> [String: Any]? {
        let level = variant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !level.isEmpty else { return nil }

        let provider = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalized = level.lowercased()

        switch provider {
        case "anthropic":
            if normalized == "none" || normalized == "off" {
                return ["thinking": ["type": "disabled"]]
            }
            let budget: Int
            switch normalized {
            case "low", "minimal":
                budget = 4_000
            case "medium":
                budget = 10_000
            case "max", "maximum", "xhigh":
                budget = 32_000
            default:
                budget = 16_000
            }
            return [
                "thinking": [
                    "type": "enabled",
                    "budgetTokens": budget
                ]
            ]
        default:
            // OpenAI / Google / xAI / Zen and most gateways accept reasoningEffort.
            if normalized == "off" {
                return ["reasoningEffort": "none"]
            }
            return ["reasoningEffort": level]
        }
    }
}

enum OpenCodeConfigurationScope: String, CaseIterable, Identifiable {
    case global
    case project

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .global:
            return "Server Default"
        case .project:
            return "This Project"
        }
    }
}

struct OpenCodeModelConfiguration: Equatable {
    let scope: OpenCodeConfigurationScope
    let modelID: String?
    let smallModelID: String?
    let enabledProviderIDs: [String]
    let disabledProviderIDs: [String]
}

struct OpenCodeCustomProviderInput: Equatable {
    var id: String
    var name: String
    var baseURL: String
    var modelID: String
    var modelName: String
    var apiKey: String
}

@MainActor
final class OpenCodeProviderService: ObservableObject {
    static let shared = OpenCodeProviderService()

    private let sshService: SSHService
    private let clientOverride: OpenCodeClient?
    private let statusCache: OpenCodeProviderStatusCache

    init(
        sshService: SSHService? = nil,
        client: OpenCodeClient? = nil,
        statusCache: OpenCodeProviderStatusCache = .shared
    ) {
        self.sshService = sshService ?? ServiceManager.shared.sshService
        self.clientOverride = client
        self.statusCache = statusCache
    }

    /// Last successful provider catalog for a server (instant UI paint).
    func cachedStatus(for serverID: UUID) -> OpenCodeProviderStatusCacheEntry? {
        statusCache.entry(for: serverID)
    }

    func status(for project: RemoteProject) async throws -> OpenCodeProviderStatus {
        let session = try await sshService.getConnection(for: project, purpose: .opencode)
        let client = client(for: project)
        let resolvedProviders = try await client.providerList(sshSession: session, directory: project.path)
        let resolvedAuthMethods = try await client.providerAuthMethods(sshSession: session, directory: project.path)
        let resolvedConfiguredProviders = try? await client.configuredProviders(sshSession: session, directory: project.path)
        let resolvedAuthEntries = await authenticatedProviderEntries(session: session)

        let status = OpenCodeProviderStatus(
            providers: resolvedProviders.all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            configuredProviders: resolvedConfiguredProviders?.providers.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            } ?? [],
            defaultModels: resolvedConfiguredProviders?.defaultModels.isEmpty == false
                ? resolvedConfiguredProviders?.defaultModels ?? resolvedProviders.defaultModels
                : resolvedProviders.defaultModels,
            connectedProviderIDs: resolvedProviders.connected.sorted(),
            authenticatedProviderIDs: resolvedAuthEntries.map(\.providerID).sorted(),
            authenticatedAuthTypes: Dictionary(uniqueKeysWithValues: resolvedAuthEntries.map { ($0.providerID, $0.authType) }),
            authMethods: resolvedAuthMethods
        )
        let previousName = statusCache.entry(for: project.serverId)?.serverName
        statusCache.store(
            OpenCodeProviderStatusCacheEntry(
                serverID: project.serverId,
                serverName: previousName ?? "Server",
                fetchedAt: Date(),
                status: status
            )
        )
        return status
    }

    func status(for server: Server) async throws -> OpenCodeProviderStatus {
        let session = try await sshService.connect(to: server, purpose: .opencode)
        defer { session.disconnect() }

        let client = client(for: server.id)
        let resolvedProviders = try await client.providerList(sshSession: session)
        let resolvedAuthMethods = try await client.providerAuthMethods(sshSession: session)
        let resolvedConfiguredProviders = try? await client.configuredProviders(sshSession: session)
        let resolvedAuthEntries = await authenticatedProviderEntries(session: session)

        let status = OpenCodeProviderStatus(
            providers: resolvedProviders.all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            configuredProviders: resolvedConfiguredProviders?.providers.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            } ?? [],
            defaultModels: resolvedConfiguredProviders?.defaultModels.isEmpty == false
                ? resolvedConfiguredProviders?.defaultModels ?? resolvedProviders.defaultModels
                : resolvedProviders.defaultModels,
            connectedProviderIDs: resolvedProviders.connected.sorted(),
            authenticatedProviderIDs: resolvedAuthEntries.map(\.providerID).sorted(),
            authenticatedAuthTypes: Dictionary(uniqueKeysWithValues: resolvedAuthEntries.map { ($0.providerID, $0.authType) }),
            authMethods: resolvedAuthMethods
        )
        statusCache.store(status, for: server)
        return status
    }

    func startOAuth(
        providerID: String,
        methodIndex: Int,
        inputs: [String: String] = [:],
        on server: Server
    ) async throws -> OpenCodeProviderOAuthAuthorization {
        let trimmedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProviderID.isEmpty else {
            throw OpenCodeProviderServiceError.invalidInput
        }

        let session = try await sshService.connect(to: server, purpose: .opencode)
        defer { session.disconnect() }

        return try await client(for: server.id).startProviderOAuth(
            sshSession: session,
            providerID: trimmedProviderID,
            methodIndex: methodIndex,
            inputs: inputs
        )
    }

    func completeOAuth(
        providerID: String,
        methodIndex: Int,
        code: String? = nil,
        on server: Server
    ) async throws {
        let trimmedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProviderID.isEmpty else {
            throw OpenCodeProviderServiceError.invalidInput
        }

        let session = try await sshService.connect(to: server, purpose: .opencode)
        defer { session.disconnect() }

        let client = client(for: server.id)
        _ = try await client.completeProviderOAuth(
            sshSession: session,
            providerID: trimmedProviderID,
            methodIndex: methodIndex,
            code: code
        )
        let _ = try? await client.disposeInstance(sshSession: session)
    }

    func removeAuth(providerID: String, on server: Server) async throws {
        let trimmedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProviderID.isEmpty else {
            throw OpenCodeProviderServiceError.invalidInput
        }

        let session = try await sshService.connect(to: server, purpose: .opencode)
        defer { session.disconnect() }

        let client = client(for: server.id)
        _ = try await client.removeProviderAuth(
            sshSession: session,
            providerID: trimmedProviderID
        )
        let _ = try? await client.disposeInstance(sshSession: session)
    }

    func saveAPIKey(_ apiKey: String, providerID: String, for project: RemoteProject) async throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedProviderID.isEmpty else {
            throw OpenCodeProviderServiceError.invalidInput
        }

        try KeychainManager.shared.storeOpenCodeAPIKey(trimmedKey, providerID: trimmedProviderID)

        try await withFreshOpenCodeSession(for: project) { session in
            let client = self.client(for: project)
            _ = try await client.setProviderAPIKey(
                sshSession: session,
                providerID: trimmedProviderID,
                apiKey: trimmedKey,
                directory: project.path
            )
        }
    }

    func applyAIProviderProfile(
        _ profile: OpenCodeAIProviderProfile,
        apiKey: String? = nil,
        to server: Server
    ) async throws {
        let normalizedProfile = profile.normalizedForStorage()
        guard normalizedProfile.isReadyToSave else {
            throw OpenCodeProviderServiceError.invalidInput
        }

        let session = try await sshService.connect(to: server, purpose: .opencode)
        defer { session.disconnect() }

        let openCodeClient = client(for: server.id)
        var loaded = try await loadGlobalConfiguration(session: session)
        if normalizedProfile.isCustomProvider {
            try loaded.document.setCustomOpenAICompatibleProvider(
                id: normalizedProfile.providerID,
                name: normalizedProfile.providerName,
                baseURL: normalizedProfile.customBaseURL,
                modelID: normalizedProfile.customModelID,
                modelName: normalizedProfile.customModelName,
                npmPackage: normalizedProfile.npmPackage
            )
        } else if normalizedProfile.usesBuiltInOpenAIProvider {
            loaded.document.removeProviderConfiguration(id: normalizedProfile.providerID)
        } else if let provider = try await catalogProvider(
            matching: normalizedProfile.providerID,
            client: openCodeClient,
            session: session
        ), provider.requiresExplicitConfiguration {
            try loaded.document.setCatalogProvider(
                provider,
                preferredModelID: OpenCodePromptModel(fullID: normalizedProfile.resolvedModelID ?? "")?.modelID
            )
        }

        // Only write `small_model` when the profile explicitly sets one.
        // Leaving it unset lets OpenCode choose a cheaper utility model.
        let explicitSmallModelID = normalizedProfile.smallModelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        loaded.document.setModelSelection(
            modelID: normalizedProfile.resolvedModelID,
            smallModelID: explicitSmallModelID.isEmpty ? nil : explicitSmallModelID
        )
        applyThinkingOptions(to: &loaded.document, profile: normalizedProfile)
        try await writeConfiguration(loaded.document, to: loaded.path, session: session)
        try await reloadConfiguration(loaded.document, client: openCodeClient, session: session, directory: nil)

        if normalizedProfile.requiresAPIKeyCredential,
           let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !apiKey.isEmpty {
            _ = try await openCodeClient.setProviderAPIKey(
                sshSession: session,
                providerID: normalizedProfile.providerID,
                apiKey: apiKey
            )
        }

        try await validateProfile(
            normalizedProfile,
            client: openCodeClient,
            session: session,
            directory: nil
        )
    }

    private func applyThinkingOptions(
        to document: inout OpenCodeMCPConfigDocument,
        profile: OpenCodeAIProviderProfile
    ) {
        guard let fullModelID = profile.resolvedModelID,
              let promptModel = OpenCodePromptModel(fullID: fullModelID) else {
            return
        }
        let options = OpenCodeThinkingSupport.modelOptions(
            variant: profile.resolvedVariant ?? "",
            providerID: profile.normalizedProviderID
        )
        document.setModelThinkingOptions(
            providerID: promptModel.providerID,
            modelID: promptModel.modelID,
            options: options
        )
    }

    func modelConfiguration(
        for project: RemoteProject,
        scope: OpenCodeConfigurationScope
    ) async throws -> OpenCodeModelConfiguration {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        let loaded = try await loadConfiguration(for: project, scope: scope, session: session)
        return OpenCodeModelConfiguration(
            scope: scope,
            modelID: loaded.document.selectedModelID,
            smallModelID: loaded.document.selectedSmallModelID,
            enabledProviderIDs: loaded.document.enabledProviderIDs,
            disabledProviderIDs: loaded.document.disabledProviderIDs
        )
    }

    func saveModelConfiguration(
        modelID: String?,
        smallModelID: String?,
        enabledProviderIDs: [String] = [],
        disabledProviderIDs: [String] = [],
        scope: OpenCodeConfigurationScope,
        for project: RemoteProject
    ) async throws {
        sshService.closeConnections(projectId: project.id, purpose: .fileOperations)
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        var loaded = try await loadConfiguration(for: project, scope: scope, session: session)
        loaded.document.setModelSelection(modelID: modelID, smallModelID: smallModelID)
        loaded.document.setProviderFilters(enabled: enabledProviderIDs, disabled: disabledProviderIDs)
        try await writeConfiguration(loaded.document, to: loaded.path, session: session)

        try await withFreshOpenCodeSession(for: project) { openCodeSession in
            try await self.reloadConfiguration(
                loaded.document,
                client: self.client(for: project),
                session: openCodeSession,
                directory: scope == .project ? project.path : nil
            )
        }
    }

    /// Force a new OpenCode-purpose SSH session, retrying once after a failed HTTP tunnel.
    /// Pooled sessions often return truncated DirectTCPIP payloads ("Missing header/body separator").
    private func withFreshOpenCodeSession(
        for project: RemoteProject,
        operation: @escaping (SSHSession) async throws -> Void
    ) async throws {
        sshService.closeConnections(projectId: project.id, purpose: .opencode)
        do {
            let session = try await sshService.getConnection(for: project, purpose: .opencode)
            try await operation(session)
        } catch {
            SSHLogger.log(
                "OpenCode SSH operation failed (\(error.localizedDescription)); retrying with fresh session",
                level: .warning
            )
            sshService.closeConnections(projectId: project.id, purpose: .opencode)
            let session = try await sshService.getConnection(for: project, purpose: .opencode)
            try await operation(session)
        }
    }

    func saveCustomOpenAICompatibleProvider(
        _ input: OpenCodeCustomProviderInput,
        scope: OpenCodeConfigurationScope,
        for project: RemoteProject
    ) async throws {
        let providerID = input.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = input.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerID.isEmpty,
              !input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !input.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !input.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.isEmpty else {
            throw OpenCodeProviderServiceError.invalidInput
        }

        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        var loaded = try await loadConfiguration(for: project, scope: scope, session: session)
        try loaded.document.setCustomOpenAICompatibleProvider(
            id: providerID,
            name: input.name,
            baseURL: input.baseURL,
            modelID: input.modelID,
            modelName: input.modelName
        )
        loaded.document.setModelSelection(modelID: "\(providerID)/\(input.modelID)", smallModelID: loaded.document.selectedSmallModelID)
        try await writeConfiguration(loaded.document, to: loaded.path, session: session)

        try KeychainManager.shared.storeOpenCodeAPIKey(apiKey, providerID: providerID)

        let client = client(for: project)
        let openCodeSession = try await sshService.getConnection(for: project, purpose: .opencode)
        try await reloadConfiguration(
            loaded.document,
            client: client,
            session: openCodeSession,
            directory: scope == .project ? project.path : nil
        )
        _ = try await client.setProviderAPIKey(
            sshSession: openCodeSession,
            providerID: providerID,
            apiKey: apiKey,
            directory: project.path
        )
        try await validateModel(
            OpenCodePromptModel(providerID: providerID, modelID: input.modelID),
            client: client,
            session: openCodeSession,
            directory: project.path
        )
    }
}

enum OpenCodeProviderServiceError: LocalizedError {
    case invalidInput
    case modelNotConfigured(String)
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Provider ID and model configuration are required."
        case .modelNotConfigured(let modelID):
            return "OpenCode did not load \(modelID). Apply the provider config and try again."
        case .validationFailed(let message):
            return "OpenCode provider validation failed: \(message)"
        }
    }
}

private extension OpenCodeProviderService {
    func client(for project: RemoteProject) -> OpenCodeClient {
        clientOverride ?? OpenCodeClientFactory.client(for: project.serverId)
    }

    func client(for serverID: UUID) -> OpenCodeClient {
        clientOverride ?? OpenCodeClientFactory.client(for: serverID)
    }

    struct AuthenticatedProviderEntry: Equatable {
        let providerID: String
        /// Normalized auth type from auth.json (`api`, `oauth`, `unknown`, …).
        let authType: String
    }

    func authenticatedProviderEntries(session: SSHSession) async -> [AuthenticatedProviderEntry] {
        let command = """
        python3 - <<'PY'
        import json
        import os
        import pathlib

        data_home = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
        auth_path = pathlib.Path(data_home) / "opencode" / "auth.json"
        try:
            data = json.loads(auth_path.read_text())
        except Exception:
            print("[]")
        else:
            entries = []
            if isinstance(data, dict):
                for key, value in data.items():
                    provider_id = str(key).strip()
                    if not provider_id:
                        continue
                    auth_type = "unknown"
                    if isinstance(value, dict):
                        raw = value.get("type") or value.get("auth") or value.get("method")
                        if raw is not None and str(raw).strip():
                            auth_type = str(raw).strip().lower()
                    entries.append({"providerID": provider_id, "authType": auth_type})
                entries.sort(key=lambda item: item["providerID"].lower())
            print(json.dumps(entries))
        PY
        """

        guard let output = try? await session.execute(command),
              let data = output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
            return []
        }

        struct Payload: Decodable {
            let providerID: String
            let authType: String
        }

        if let payloads = try? JSONDecoder().decode([Payload].self, from: data) {
            return payloads.map {
                AuthenticatedProviderEntry(
                    providerID: $0.providerID,
                    authType: $0.authType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                )
            }
        }

        // Backward-compatible parse if the remote still returns a plain id list.
        if let providerIDs = try? JSONDecoder().decode([String].self, from: data) {
            return providerIDs.map {
                AuthenticatedProviderEntry(providerID: $0, authType: "unknown")
            }
        }

        return []
    }

    func authenticatedProviderIDs(session: SSHSession) async -> [String] {
        await authenticatedProviderEntries(session: session).map(\.providerID)
    }

    func catalogProvider(
        matching providerID: String,
        client: OpenCodeClient,
        session: SSHSession
    ) async throws -> OpenCodeProvider? {
        let normalizedID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return nil }
        let response = try await client.providerList(sshSession: session)
        return response.all.first { provider in
            provider.id.caseInsensitiveCompare(normalizedID) == .orderedSame
        }
    }

    func reloadConfiguration(
        _ document: OpenCodeMCPConfigDocument,
        client: OpenCodeClient,
        session: SSHSession,
        directory: String?
    ) async throws {
        try await client.patchConfiguration(
            sshSession: session,
            json: document.toJSONString(),
            directory: directory
        )
    }

    func validateProfile(
        _ profile: OpenCodeAIProviderProfile,
        client: OpenCodeClient,
        session: SSHSession,
        directory: String?
    ) async throws {
        guard let modelID = profile.resolvedModelID,
              let model = OpenCodePromptModel(fullID: modelID) else {
            return
        }
        try await validateModel(model, client: client, session: session, directory: directory)
    }

    func validateModel(
        _ model: OpenCodePromptModel,
        client: OpenCodeClient,
        session: SSHSession,
        directory: String?
    ) async throws {
        try await ensureModelKnownToOpenCode(model, client: client, session: session, directory: directory)

        let created = try await client.createSession(
            sshSession: session,
            title: "CodeAgents provider validation",
            directory: directory
        )
        guard let sessionID = created.id?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            throw OpenCodeClientError.invalidResponse("OpenCode did not return a validation session id.")
        }

        let eventPath = OpenCodeSessionPath.path("/event", directory: directory)
        let eventIterator = OpenCodeProviderValidationEventIterator(
            stream: client.streamEvents(session: session, path: eventPath)
        )
        _ = try await nextValidationEvent(
            from: eventIterator,
            timeoutNanoseconds: 5_000_000_000
        )

        try await client.promptAsync(
            sshSession: session,
            sessionID: sessionID,
            payload: OpenCodePromptPayload(
                model: model,
                system: "Validate the provider connection. Reply with exactly OK.",
                tools: [:],
                parts: [.text("Reply with exactly OK.")]
            ),
            directory: directory
        )

        try await waitForValidationReply(
            sessionID: sessionID,
            model: model,
            eventIterator: eventIterator
        )
    }

    /// Prefer live catalog (`/provider`). Only fall back to `/config/providers` when the catalog
    /// has no models for the provider (custom endpoints). Config-only free-text ids on catalog
    /// providers are rejected so stale opencode.json entries cannot pass validation.
    func ensureModelKnownToOpenCode(
        _ model: OpenCodePromptModel,
        client: OpenCodeClient,
        session: SSHSession,
        directory: String?
    ) async throws {
        let catalog = try? await client.providerList(sshSession: session, directory: directory)
        if let catalogProvider = catalog?.all.first(where: {
            $0.id.caseInsensitiveCompare(model.providerID) == .orderedSame
        }), !catalogProvider.models.isEmpty {
            let known = catalogProvider.models.values.contains {
                $0.id.caseInsensitiveCompare(model.modelID) == .orderedSame
            }
            guard known else {
                throw OpenCodeProviderServiceError.modelNotConfigured(model.fullID)
            }
            return
        }

        let configured = try await client.configuredProviders(sshSession: session, directory: directory)
        guard configured.providers.contains(where: { provider in
            provider.id.caseInsensitiveCompare(model.providerID) == .orderedSame
                && provider.models.values.contains { $0.id.caseInsensitiveCompare(model.modelID) == .orderedSame }
        }) else {
            throw OpenCodeProviderServiceError.modelNotConfigured(model.fullID)
        }
    }

    func waitForValidationReply(
        sessionID: String,
        model: OpenCodePromptModel,
        eventIterator: OpenCodeProviderValidationEventIterator
    ) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let remaining = UInt64(max(1, deadline.timeIntervalSinceNow) * 1_000_000_000)
            guard let event = try await nextValidationEvent(
                from: eventIterator,
                timeoutNanoseconds: min(remaining, 5_000_000_000)
            ) else {
                continue
            }

            switch event {
            case .sessionError(let properties, _):
                guard validationEventMatches(properties.sessionID, sessionID: sessionID) else { continue }
                throw OpenCodeProviderServiceError.validationFailed(properties.error.displayMessage)

            case .messageUpdated(let properties, _):
                guard validationEventMatches(properties.sessionID ?? properties.info.sessionID, sessionID: sessionID) else {
                    continue
                }
                if let error = properties.info.error {
                    throw OpenCodeProviderServiceError.validationFailed(error.displayMessage)
                }
                if properties.info.role != "user" {
                    return
                }

            case .messagePartUpdated(let properties, _):
                guard validationEventMatches(properties.sessionID ?? properties.part.payload.sessionID, sessionID: sessionID) else {
                    continue
                }
                if let error = properties.part.payload.error {
                    throw OpenCodeProviderServiceError.validationFailed(error.displayMessage)
                }
                if properties.part.payload.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    return
                }

            case .messagePartDelta(let properties, _):
                guard validationEventMatches(properties.sessionID ?? properties.part?.payload.sessionID, sessionID: sessionID) else {
                    continue
                }
                if properties.delta?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    || properties.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    return
                }

            case .sessionIdle(let properties, _):
                guard validationEventMatches(properties.sessionID ?? properties.id, sessionID: sessionID) else { continue }
                return

            case .sessionStatus(let properties, _):
                guard validationEventMatches(properties.sessionID, sessionID: sessionID),
                      properties.status.type == "idle" else { continue }
                return

            default:
                continue
            }
        }

        throw OpenCodeProviderServiceError.validationFailed(
            "\(model.fullID) accepted the prompt but did not return a validation reply."
        )
    }

    func nextValidationEvent(
        from iterator: OpenCodeProviderValidationEventIterator,
        timeoutNanoseconds: UInt64
    ) async throws -> OpenCodeEvent? {
        try await withThrowingTaskGroup(of: OpenCodeEvent?.self) { group in
            group.addTask {
                try await iterator.next()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }

            guard let result = try await group.next() else {
                return nil
            }
            group.cancelAll()
            return result
        }
    }

    func validationEventMatches(_ candidate: String?, sessionID: String) -> Bool {
        candidate?.trimmingCharacters(in: .whitespacesAndNewlines) == sessionID
    }

    func loadConfiguration(
        for project: RemoteProject,
        scope: OpenCodeConfigurationScope,
        session: SSHSession
    ) async throws -> (path: String, document: OpenCodeMCPConfigDocument) {
        if scope == .global {
            return try await loadGlobalConfiguration(session: session)
        }

        let jsonPath = "\(project.path)/opencode.json"
        if let document = try await readConfigurationIfPresent(at: jsonPath, session: session) {
            return (jsonPath, document)
        }

        let jsoncPath = "\(project.path)/opencode.jsonc"
        if let document = try await readConfigurationIfPresent(at: jsoncPath, session: session) {
            return (jsoncPath, document)
        }

        return (jsonPath, OpenCodeMCPConfigDocument())
    }

    func loadGlobalConfiguration(session: SSHSession) async throws -> (path: String, document: OpenCodeMCPConfigDocument) {
        let path = try await globalConfigurationPath(session: session)
        return (path, try await readConfiguration(at: path, session: session))
    }

    func readConfiguration(at path: String, session: SSHSession) async throws -> OpenCodeMCPConfigDocument {
        if let document = try await readConfigurationIfPresent(at: path, session: session) {
            return document
        }
        return OpenCodeMCPConfigDocument()
    }

    func readConfigurationIfPresent(at path: String, session: SSHSession) async throws -> OpenCodeMCPConfigDocument? {
        do {
            return try OpenCodeMCPConfigDocument(jsonString: try await session.readFile(path))
        } catch {
            let errorMessage = error.localizedDescription.lowercased()
            if errorMessage.contains("no such file") || errorMessage.contains("cannot open") {
                return nil
            }
            throw error
        }
    }

    func writeConfiguration(
        _ document: OpenCodeMCPConfigDocument,
        to path: String,
        session: SSHSession
    ) async throws {
        guard let data = try document.toJSONString().data(using: .utf8) else {
            throw OpenCodeProviderServiceError.invalidInput
        }
        let base64 = data.base64EncodedString()
        let escapedPath = escapeForDoubleQuotes(path)
        let command = "mkdir -p \"$(dirname \"\(escapedPath)\")\" && printf '%s' '\(base64)' | base64 -d > \"\(escapedPath)\""
        _ = try await session.execute(command)
    }

    func globalConfigurationPath(session: SSHSession) async throws -> String {
        let command = "printf '%s' \"${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json\""
        let path = try await session.execute(command).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw OpenCodeProviderServiceError.invalidInput
        }
        return path
    }

    func escapeForDoubleQuotes(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }

}

private actor OpenCodeProviderValidationEventIterator {
    private var iterator: AsyncThrowingStream<OpenCodeEvent, Error>.Iterator

    init(stream: AsyncThrowingStream<OpenCodeEvent, Error>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> OpenCodeEvent? {
        var activeIterator = iterator
        let event = try await activeIterator.next()
        iterator = activeIterator
        return event
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
