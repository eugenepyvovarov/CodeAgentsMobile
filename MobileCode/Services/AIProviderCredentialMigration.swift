//
//  AIProviderCredentialMigration.swift
//  CodeAgentsMobile
//
//  Purpose: Explicit copy-only reuse of compatible legacy Claude provider API keys for OpenCode.
//

import Foundation

enum AIProviderCredentialMigration {
    static func compatibleLegacyClaudeProvider(forOpenCodeProviderID providerID: String) -> ClaudeModelProvider? {
        KeychainManager.legacyClaudeProvider(forOpenCodeProviderID: providerID)
    }

    static func canCopyLegacyAPIKeyForOpenCode(
        providerID: String,
        keychain: KeychainManager = .shared
    ) -> Bool {
        guard let legacyProvider = compatibleLegacyClaudeProvider(forOpenCodeProviderID: providerID),
              keychain.hasAPIKey(provider: legacyProvider),
              !keychain.hasOpenCodeAPIKey(providerID: providerID) else {
            return false
        }

        return true
    }

    @discardableResult
    static func copyLegacyAPIKeyForOpenCode(
        providerID: String,
        keychain: KeychainManager = .shared
    ) throws -> ClaudeModelProvider {
        guard let legacyProvider = compatibleLegacyClaudeProvider(forOpenCodeProviderID: providerID),
              !keychain.hasOpenCodeAPIKey(providerID: providerID) else {
            throw KeychainManager.KeychainError.itemNotFound
        }

        let apiKey = try keychain.retrieveAPIKey(provider: legacyProvider)
        try keychain.storeOpenCodeAPIKey(apiKey, providerID: providerID)
        return legacyProvider
    }
}
