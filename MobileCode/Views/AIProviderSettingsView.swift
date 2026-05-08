//
//  AIProviderSettingsView.swift
//  CodeAgentsMobile
//
//  Purpose: Unified AI provider settings surface for OpenCode and Claude Code Proxy
//

import SwiftUI

enum AIProviderSettingsMode: String, CaseIterable, Identifiable {
    case openCode
    case claudeProxy

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openCode:
            return "OpenCode"
        case .claudeProxy:
            return "Claude Code Proxy"
        }
    }
}

struct AIProviderSettingsView: View {
    @State private var selectedMode: AIProviderSettingsMode

    init(initialMode: AIProviderSettingsMode = .openCode) {
        _selectedMode = State(initialValue: initialMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Provider Mode", selection: $selectedMode) {
                ForEach(AIProviderSettingsMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top])
            .accessibilityIdentifier("ai-provider-settings-mode-picker")

            Group {
                switch selectedMode {
                case .openCode:
                    OpenCodeAIProviderSettingsView(navigationTitle: "AI Providers")
                case .claudeProxy:
                    ClaudeProviderSettingsView(navigationTitle: "AI Providers")
                }
            }
        }
        .navigationTitle("AI Providers")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("ai-providers-settings-view")
    }
}

#Preview("AI Providers - OpenCode") {
    NavigationStack {
        AIProviderSettingsView()
    }
    .modelContainer(for: [Server.self], inMemory: true)
}

#Preview("AI Providers - Claude Code Proxy") {
    NavigationStack {
        AIProviderSettingsView(initialMode: .claudeProxy)
    }
    .modelContainer(for: [Server.self], inMemory: true)
}
