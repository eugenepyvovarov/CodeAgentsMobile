//
//  AIProviderSettingsView.swift
//  CodeAgentsMobile
//
//  Purpose: AI provider settings (OpenCode). Legacy Claude mode remains only for task-daemon credentials.
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
            return "Task Provider"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .openCode:
            return "ai-provider-mode-opencode"
        case .claudeProxy:
            return "ai-provider-mode-claude-proxy"
        }
    }
}

struct AIProviderSettingsView: View {
    let server: Server?
    private let mode: AIProviderSettingsMode

    init(initialMode: AIProviderSettingsMode = .openCode, server: Server? = nil) {
        self.server = server
        self.mode = initialMode
    }

    var body: some View {
        Group {
            switch mode {
            case .openCode:
                // OpenCode is the only chat runtime — no dual-mode segmented control.
                OpenCodeAIProviderSettingsView(server: server, navigationTitle: "AI Providers")
            case .claudeProxy:
                // Scheduled-task / agent-daemon credential flows only (not chat).
                ClaudeProviderSettingsView(navigationTitle: "Task Provider")
            }
        }
        .navigationTitle(mode == .openCode ? "AI Providers" : "Task Provider")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("ai-providers-settings-view")
        // Stable marker for UI tests: OpenCode path has no mode picker.
        .background(
            Text(mode.displayName)
                .accessibilityIdentifier("ai-provider-settings-mode")
                .accessibilityValue(mode.rawValue)
                .opacity(0.01)
                .allowsHitTesting(false)
        )
    }
}

#Preview("AI Providers - OpenCode") {
    NavigationStack {
        AIProviderSettingsView()
    }
    .modelContainer(for: [Server.self], inMemory: true)
}

#Preview("Task Provider") {
    NavigationStack {
        AIProviderSettingsView(initialMode: .claudeProxy)
    }
    .modelContainer(for: [Server.self], inMemory: true)
}
