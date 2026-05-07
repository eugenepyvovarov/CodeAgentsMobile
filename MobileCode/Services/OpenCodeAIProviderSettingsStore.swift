//
//  OpenCodeAIProviderSettingsStore.swift
//  CodeAgentsMobile
//
//  Purpose: Local OpenCode AI provider defaults and per-server overrides
//

import Foundation

enum OpenCodeProviderAuthMode: String, Codable, CaseIterable, Identifiable {
    case apiKey
    case openAIChatGPT

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apiKey:
            return "API Key"
        case .openAIChatGPT:
            return "OpenAI ChatGPT Plus/Pro"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .apiKey:
            return true
        case .openAIChatGPT:
            return false
        }
    }
}

enum OpenCodeProviderNPMDriver: String, Codable, CaseIterable, Identifiable {
    case openAICompatible = "@ai-sdk/openai-compatible"
    case openAIResponses = "@ai-sdk/openai"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAICompatible:
            return "OpenAI compatible"
        case .openAIResponses:
            return "OpenAI Responses"
        }
    }
}

struct OpenCodeAIProviderProfile: Codable, Equatable {
    var providerID: String
    var providerName: String
    var authModeRawValue: String
    var modelID: String
    var smallModelID: String
    var customBaseURL: String
    var customModelID: String
    var customModelName: String
    var npmPackage: String

    init(
        providerID: String = "openai",
        providerName: String = "OpenAI",
        authMode: OpenCodeProviderAuthMode = .apiKey,
        modelID: String = "",
        smallModelID: String = "",
        customBaseURL: String = "",
        customModelID: String = "",
        customModelName: String = "",
        npmPackage: String = OpenCodeProviderNPMDriver.openAICompatible.rawValue
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.authModeRawValue = authMode.rawValue
        self.modelID = modelID
        self.smallModelID = smallModelID
        self.customBaseURL = customBaseURL
        self.customModelID = customModelID
        self.customModelName = customModelName
        self.npmPackage = npmPackage
    }

    static func defaults() -> OpenCodeAIProviderProfile {
        OpenCodeAIProviderProfile()
    }

    var authMode: OpenCodeProviderAuthMode {
        get {
            OpenCodeProviderAuthMode(rawValue: authModeRawValue) ?? .apiKey
        }
        set {
            authModeRawValue = newValue.rawValue
            if newValue == .openAIChatGPT {
                providerID = "openai"
                if providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    providerName = "OpenAI"
                }
            }
        }
    }

    var npmDriver: OpenCodeProviderNPMDriver {
        get {
            OpenCodeProviderNPMDriver(rawValue: npmPackage) ?? .openAICompatible
        }
        set {
            npmPackage = newValue.rawValue
        }
    }

    var normalizedProviderID: String {
        providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var trimmedProviderName: String {
        let trimmed = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? normalizedProviderID : trimmed
    }

    var isCustomProvider: Bool {
        !customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !customModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var usesBuiltInOpenAIProvider: Bool {
        normalizedProviderID == "openai" && !isCustomProvider
    }

    var requiresAPIKeyCredential: Bool {
        authMode.requiresAPIKey && normalizedProviderID != "opencode"
    }

    var resolvedModelID: String? {
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModelID.isEmpty {
            return trimmedModelID
        }

        let providerID = normalizedProviderID
        let customModelID = customModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerID.isEmpty, !customModelID.isEmpty else {
            return nil
        }
        return "\(providerID)/\(customModelID)"
    }

    var resolvedSmallModelID: String? {
        let trimmedSmallModelID = smallModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedSmallModelID.isEmpty ? resolvedModelID : trimmedSmallModelID
    }

    var isReadyToSave: Bool {
        !normalizedProviderID.isEmpty
            && (!isCustomProvider || (
                !trimmedProviderName.isEmpty
                    && !customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !customModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ))
    }

    func normalizedForStorage() -> OpenCodeAIProviderProfile {
        var copy = self
        copy.providerID = normalizedProviderID
        copy.providerName = trimmedProviderName
        copy.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.smallModelID = smallModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.customBaseURL = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.customModelID = customModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.customModelName = customModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.npmPackage = npmDriver.rawValue
        copy.authModeRawValue = authMode.rawValue
        return copy
    }
}

struct OpenCodeServerAIProviderOverride: Codable, Equatable {
    var usesGlobalDefaults: Bool
    var profile: OpenCodeAIProviderProfile

    init(usesGlobalDefaults: Bool = true, profile: OpenCodeAIProviderProfile = .defaults()) {
        self.usesGlobalDefaults = usesGlobalDefaults
        self.profile = profile
    }
}

struct OpenCodeAIProviderSettingsStore {
    static let globalProfileKey = "OpenCodeAIProviderSettings.GlobalProfile"
    static let serverOverridesKey = "OpenCodeAIProviderSettings.ServerOverrides"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func globalProfile() -> OpenCodeAIProviderProfile {
        guard let data = userDefaults.data(forKey: Self.globalProfileKey),
              let profile = try? JSONDecoder().decode(OpenCodeAIProviderProfile.self, from: data) else {
            return .defaults()
        }
        return profile.normalizedForStorage()
    }

    func saveGlobalProfile(_ profile: OpenCodeAIProviderProfile) throws {
        let data = try JSONEncoder().encode(profile.normalizedForStorage())
        userDefaults.set(data, forKey: Self.globalProfileKey)
    }

    func serverOverride(for serverID: UUID) -> OpenCodeServerAIProviderOverride {
        serverOverrides()[serverID.uuidString] ?? OpenCodeServerAIProviderOverride()
    }

    func saveServerOverride(_ override: OpenCodeServerAIProviderOverride, for serverID: UUID) throws {
        var overrides = serverOverrides()
        overrides[serverID.uuidString] = OpenCodeServerAIProviderOverride(
            usesGlobalDefaults: override.usesGlobalDefaults,
            profile: override.profile.normalizedForStorage()
        )
        try saveServerOverrides(overrides)
    }

    func deleteServerOverride(for serverID: UUID) throws {
        var overrides = serverOverrides()
        overrides.removeValue(forKey: serverID.uuidString)
        try saveServerOverrides(overrides)
    }

    func effectiveProfile(for serverID: UUID) -> OpenCodeAIProviderProfile {
        let override = serverOverride(for: serverID)
        return override.usesGlobalDefaults ? globalProfile() : override.profile.normalizedForStorage()
    }

    private func serverOverrides() -> [String: OpenCodeServerAIProviderOverride] {
        guard let data = userDefaults.data(forKey: Self.serverOverridesKey),
              let overrides = try? JSONDecoder().decode([String: OpenCodeServerAIProviderOverride].self, from: data) else {
            return [:]
        }
        return overrides
    }

    private func saveServerOverrides(_ overrides: [String: OpenCodeServerAIProviderOverride]) throws {
        let data = try JSONEncoder().encode(overrides)
        userDefaults.set(data, forKey: Self.serverOverridesKey)
    }
}
