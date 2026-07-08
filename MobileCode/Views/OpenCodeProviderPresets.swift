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
    let supportsChatGPT: Bool
}

enum OpenCodeProviderPreset {
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
