//
//  OpenCodeProviderPresets.swift
//  CodeAgentsMobile
//
//  Purpose: Provider choice model and preferred OpenCode provider presets
//

import Foundation

struct OpenCodeProviderChoice: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let systemImage: String
    let isCustom: Bool
    let isConnected: Bool
    /// True when OpenCode exposes at least one OAuth method for this provider.
    let supportsOAuth: Bool
}

enum OpenCodeProviderPreset {
    /// Providers known to ship OAuth / subscription connect plugins in OpenCode.
    /// Live `authMethods` from the server still win when available.
    static let knownOAuthProviderIDs: Set<String> = [
        "openai",
        "xai",
        "github-copilot",
        "gitlab",
        "digitalocean",
        "opencode",
        "poe",
        "snowflake-cortex"
    ]

    static let preferred: [OpenCodeProviderChoice] = [
        OpenCodeProviderChoice(
            id: "opencode",
            name: "OpenCode Zen",
            subtitle: "Recommended tested coding models",
            systemImage: "checkmark.seal",
            isCustom: false,
            isConnected: false,
            supportsOAuth: true
        ),
        OpenCodeProviderChoice(
            id: "openai",
            name: "OpenAI",
            subtitle: "GPT and ChatGPT Plus/Pro (headless OAuth)",
            systemImage: "sparkles",
            isCustom: false,
            isConnected: false,
            supportsOAuth: true
        ),
        OpenCodeProviderChoice(
            id: "xai",
            name: "xAI",
            subtitle: "Grok / SuperGrok (headless OAuth)",
            systemImage: "xmark.circle",
            isCustom: false,
            isConnected: false,
            supportsOAuth: true
        ),
        OpenCodeProviderChoice(
            id: "github-copilot",
            name: "GitHub Copilot",
            subtitle: "Copilot subscription (device login)",
            systemImage: "chevron.left.forwardslash.chevron.right",
            isCustom: false,
            isConnected: false,
            supportsOAuth: true
        ),
        OpenCodeProviderChoice(
            id: "gitlab",
            name: "GitLab Duo",
            subtitle: "GitLab Duo Agent Platform",
            systemImage: "point.topleft.down.to.point.bottomright.curvepath",
            isCustom: false,
            isConnected: false,
            supportsOAuth: true
        ),
        OpenCodeProviderChoice(
            id: "digitalocean",
            name: "DigitalOcean",
            subtitle: "Inference Engine + routers",
            systemImage: "drop.fill",
            isCustom: false,
            isConnected: false,
            supportsOAuth: true
        ),
        OpenCodeProviderChoice(
            id: "anthropic",
            name: "Anthropic",
            subtitle: "Claude models (API key)",
            systemImage: "brain.head.profile",
            isCustom: false,
            isConnected: false,
            supportsOAuth: false
        ),
        OpenCodeProviderChoice(
            id: "openrouter",
            name: "OpenRouter",
            subtitle: "Many providers through one API",
            systemImage: "point.3.connected.trianglepath.dotted",
            isCustom: false,
            isConnected: false,
            supportsOAuth: false
        ),
        OpenCodeProviderChoice(
            id: "google",
            name: "Google",
            subtitle: "Gemini models",
            systemImage: "globe",
            isCustom: false,
            isConnected: false,
            supportsOAuth: false
        ),
        OpenCodeProviderChoice(
            id: "minimax",
            name: "MiniMax",
            subtitle: "M2 coding models",
            systemImage: "bolt.horizontal.circle",
            isCustom: false,
            isConnected: false,
            supportsOAuth: false
        )
    ]

    static func name(for providerID: String) -> String? {
        preferred.first { $0.id.caseInsensitiveCompare(providerID) == .orderedSame }?.name
    }

    static func symbol(for providerID: String) -> String {
        preferred.first { $0.id.caseInsensitiveCompare(providerID) == .orderedSame }?.systemImage ?? "cpu"
    }

    static func supportsOAuth(for providerID: String) -> Bool {
        let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return knownOAuthProviderIDs.contains(normalized)
            || preferred.contains { $0.id == normalized && $0.supportsOAuth }
    }

    /// Friendly label for an OAuth method on a known provider.
    static func oauthDisplayName(providerID: String, methodLabel: String?) -> String {
        let method = methodLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !method.isEmpty {
            return method
        }
        switch providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "openai":
            return "ChatGPT Plus/Pro"
        case "xai":
            return "SuperGrok / xAI OAuth"
        case "github-copilot":
            return "GitHub Copilot"
        case "gitlab":
            return "GitLab OAuth"
        case "digitalocean":
            return "DigitalOcean OAuth"
        case "opencode":
            return "OpenCode Console"
        default:
            return "OAuth / Subscription"
        }
    }
}
