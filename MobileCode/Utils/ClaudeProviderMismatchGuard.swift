//
//  ClaudeProviderMismatchGuard.swift
//  CodeAgentsMobile
//
//  Purpose: Detect when the selected Claude provider differs from the provider that last
//  successfully ran a chat for a given project. Used to gate sends and show a reset banner.
//

import Foundation

struct ClaudeProviderMismatch: Equatable {
    let previous: ClaudeModelProvider
    let current: ClaudeModelProvider

    var title: String {
        "Provider changed: \(previous.displayName) → \(current.displayName)"
    }

    var message: String {
        "Clear chat to continue, or switch back to \(previous.displayName)."
    }
}

enum ClaudeProviderMismatchGuard {
    static func currentProvider(userDefaults: UserDefaults = .standard) -> ClaudeModelProvider {
        ClaudeProviderConfigurationStore.load(userDefaults: userDefaults).selectedProvider
    }

    static func mismatch(
        lastSuccessfulProvider: ClaudeModelProvider?,
        currentProvider: ClaudeModelProvider
    ) -> ClaudeProviderMismatch? {
        guard let lastSuccessfulProvider else { return nil }
        guard lastSuccessfulProvider != currentProvider else { return nil }
        return ClaudeProviderMismatch(previous: lastSuccessfulProvider, current: currentProvider)
    }

    static func mismatch(
        for project: RemoteProject?,
        userDefaults: UserDefaults = .standard
    ) -> ClaudeProviderMismatch? {
        guard let project else { return nil }
        let current = currentProvider(userDefaults: userDefaults)
        let previous = project.lastSuccessfulClaudeProviderRawValue.flatMap { ClaudeModelProvider(rawValue: $0) }
        return mismatch(lastSuccessfulProvider: previous, currentProvider: current)
    }
}

