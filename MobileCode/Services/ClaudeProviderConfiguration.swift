//
//  ClaudeProviderConfiguration.swift
//  CodeAgentsMobile
//
//  Purpose: Persist and resolve Claude provider + model overrides for Anthropic-compatible endpoints.
//

import Foundation

enum ClaudeModelProvider: String, CaseIterable, Identifiable, Codable {
    case anthropic
    case zAI = "zai"
    case miniMax = "minimax"
    case moonshot
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic:
            return "Anthropic"
        case .zAI:
            return "Z.ai"
        case .miniMax:
            return "MiniMax"
        case .moonshot:
            return "Moonshot"
        case .custom:
            return "Custom"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .anthropic:
            return ""
        case .zAI:
            return "https://api.z.ai/api/anthropic"
        case .miniMax:
            return "https://api.minimax.io/anthropic"
        case .moonshot:
            return "https://api.moonshot.ai/anthropic"
        case .custom:
            return ""
        }
    }
}

struct ClaudeProviderOverrides: Codable, Equatable {
    var baseURL: String
    var apiTimeoutMs: Int
    var disableNonessentialTraffic: Bool

    /// Sets `ANTHROPIC_MODEL`
    var model: String

    /// Sets `ANTHROPIC_SMALL_FAST_MODEL`
    var smallFastModel: String

    /// Sets `ANTHROPIC_DEFAULT_*_MODEL`
    var defaultOpusModel: String
    var defaultSonnetModel: String
    var defaultHaikuModel: String

    static func defaults(for provider: ClaudeModelProvider) -> ClaudeProviderOverrides {
        switch provider {
        case .anthropic:
            return ClaudeProviderOverrides(
                baseURL: "",
                apiTimeoutMs: 0,
                disableNonessentialTraffic: false,
                model: "",
                smallFastModel: "",
                defaultOpusModel: "",
                defaultSonnetModel: "",
                defaultHaikuModel: ""
            )
        case .zAI:
            return ClaudeProviderOverrides(
                baseURL: provider.defaultBaseURL,
                apiTimeoutMs: 3_000_000,
                disableNonessentialTraffic: false,
                model: "GLM-4.7",
                smallFastModel: "GLM-4.5-Air",
                defaultOpusModel: "GLM-4.7",
                defaultSonnetModel: "GLM-4.7",
                defaultHaikuModel: "GLM-4.5-Air"
            )
        case .miniMax:
            return ClaudeProviderOverrides(
                baseURL: provider.defaultBaseURL,
                apiTimeoutMs: 3_000_000,
                disableNonessentialTraffic: false,
                model: "MiniMax-M2.1",
                smallFastModel: "MiniMax-M2.1",
                defaultOpusModel: "MiniMax-M2.1",
                defaultSonnetModel: "MiniMax-M2.1",
                defaultHaikuModel: "MiniMax-M2.1"
            )
        case .moonshot:
            return ClaudeProviderOverrides(
                baseURL: provider.defaultBaseURL,
                apiTimeoutMs: 3_000_000,
                disableNonessentialTraffic: false,
                model: "kimi-k2-thinking-turbo",
                smallFastModel: "kimi-k2-thinking-turbo",
                defaultOpusModel: "kimi-k2-thinking-turbo",
                defaultSonnetModel: "kimi-k2-thinking-turbo",
                defaultHaikuModel: "kimi-k2-thinking-turbo"
            )
        case .custom:
            return ClaudeProviderOverrides(
                baseURL: "",
                apiTimeoutMs: 3_000_000,
                disableNonessentialTraffic: false,
                model: "",
                smallFastModel: "",
                defaultOpusModel: "",
                defaultSonnetModel: "",
                defaultHaikuModel: ""
            )
        }
    }
}

struct ClaudeProviderConfiguration: Codable, Equatable {
    var selectedProvider: ClaudeModelProvider
    var overridesByProvider: [String: ClaudeProviderOverrides]

    static func defaults() -> ClaudeProviderConfiguration {
        var overrides: [String: ClaudeProviderOverrides] = [:]
        for provider in ClaudeModelProvider.allCases {
            overrides[provider.rawValue] = ClaudeProviderOverrides.defaults(for: provider)
        }
        return ClaudeProviderConfiguration(selectedProvider: .anthropic, overridesByProvider: overrides)
    }

    func overrides(for provider: ClaudeModelProvider) -> ClaudeProviderOverrides {
        overridesByProvider[provider.rawValue] ?? ClaudeProviderOverrides.defaults(for: provider)
    }

    mutating func setOverrides(_ overrides: ClaudeProviderOverrides, for provider: ClaudeModelProvider) {
        overridesByProvider[provider.rawValue] = overrides
    }
}

enum ClaudeProviderConfigurationStore {
    static let configurationKey = "claudeProviderConfiguration.v1"

    static func load(userDefaults: UserDefaults = .standard) -> ClaudeProviderConfiguration {
        guard let data = userDefaults.data(forKey: configurationKey) else {
            return ClaudeProviderConfiguration.defaults()
        }

        do {
            let decoded = try JSONDecoder().decode(ClaudeProviderConfiguration.self, from: data)
            return decoded
        } catch {
            return ClaudeProviderConfiguration.defaults()
        }
    }

    static func save(_ configuration: ClaudeProviderConfiguration, userDefaults: UserDefaults = .standard) {
        do {
            let data = try JSONEncoder().encode(configuration)
            userDefaults.set(data, forKey: configurationKey)
        } catch {
            // Ignore save failures; settings will fall back to defaults.
        }
    }
}
