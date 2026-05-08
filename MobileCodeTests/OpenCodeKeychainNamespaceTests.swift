import XCTest
@testable import CodeAgentsMobile

final class OpenCodeKeychainNamespaceTests: XCTestCase {
    func testOpenCodeAPIKeyAccountUsesRuntimeNamespace() {
        XCTAssertEqual(
            KeychainManager.openCodeAPIKeyAccount(for: "Anthropic"),
            "opencode_provider_api_key_anthropic"
        )
        XCTAssertEqual(
            KeychainManager.openCodeAPIKeyAccount(for: "github/copilot"),
            "opencode_provider_api_key_github_copilot"
        )
    }

    func testOpenCodeServerPasswordAccountUsesRuntimeNamespace() {
        let serverID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        XCTAssertEqual(
            KeychainManager.openCodeServerPasswordAccount(for: serverID),
            "opencode_server_password_11111111-2222-3333-4444-555555555555"
        )
        XCTAssertEqual(
            KeychainManager.openCodeServerUsernameAccount(for: serverID),
            "opencode_server_username_11111111-2222-3333-4444-555555555555"
        )
    }

    func testOpenCodeServerPasswordRoundTripsByServerID() throws {
        let serverID = UUID()
        defer {
            try? KeychainManager.shared.deleteOpenCodeServerCredentials(for: serverID)
        }

        try KeychainManager.shared.storeOpenCodeServerPassword("fixture_password", for: serverID)

        XCTAssertTrue(KeychainManager.shared.hasOpenCodeServerPassword(for: serverID))
        XCTAssertEqual(
            try KeychainManager.shared.retrieveOpenCodeServerPassword(for: serverID),
            "fixture_password"
        )
    }

    func testOpenCodeServerCredentialsRoundTripWithUsername() throws {
        let serverID = UUID()
        defer {
            try? KeychainManager.shared.deleteOpenCodeServerCredentials(for: serverID)
        }

        try KeychainManager.shared.storeOpenCodeServerCredentials(
            username: "mobile",
            password: "fixture_password",
            for: serverID
        )

        XCTAssertEqual(try KeychainManager.shared.retrieveOpenCodeServerUsername(for: serverID), "mobile")
        XCTAssertEqual(try KeychainManager.shared.retrieveOpenCodeServerPassword(for: serverID), "fixture_password")
    }

    func testOpenCodeServerUsernameDefaultsToManagedUsername() throws {
        let serverID = UUID()
        defer {
            try? KeychainManager.shared.deleteOpenCodeServerCredentials(for: serverID)
        }

        XCTAssertEqual(
            try KeychainManager.shared.retrieveOpenCodeServerUsername(for: serverID),
            OpenCodeServerProvisioning.username
        )
    }

    func testLegacyClaudeProviderMappingForExplicitOpenCodeCopy() {
        XCTAssertEqual(AIProviderCredentialMigration.compatibleLegacyClaudeProvider(forOpenCodeProviderID: "anthropic"), .anthropic)
        XCTAssertEqual(AIProviderCredentialMigration.compatibleLegacyClaudeProvider(forOpenCodeProviderID: "z.ai"), .zAI)
        XCTAssertEqual(AIProviderCredentialMigration.compatibleLegacyClaudeProvider(forOpenCodeProviderID: "minimax"), .miniMax)
        XCTAssertEqual(AIProviderCredentialMigration.compatibleLegacyClaudeProvider(forOpenCodeProviderID: "moonshot"), .moonshot)
        XCTAssertNil(AIProviderCredentialMigration.compatibleLegacyClaudeProvider(forOpenCodeProviderID: "openai"))
    }

    func testOpenCodeAPIKeyLookupDoesNotFallBackToLegacyClaudeKey() throws {
        let providerID = "minimax"
        defer {
            try? KeychainManager.shared.deleteAPIKey(provider: .miniMax)
            try? KeychainManager.shared.deleteOpenCodeAPIKey(providerID: providerID)
        }
        try? KeychainManager.shared.deleteAPIKey(provider: .miniMax)
        try? KeychainManager.shared.deleteOpenCodeAPIKey(providerID: providerID)

        try KeychainManager.shared.storeAPIKey("legacy-minimax-key", provider: .miniMax)

        XCTAssertThrowsError(try KeychainManager.shared.retrieveOpenCodeAPIKey(providerID: providerID)) { error in
            guard case KeychainManager.KeychainError.itemNotFound = error else {
                return XCTFail("Expected missing OpenCode key, got \(error)")
            }
        }
        XCTAssertFalse(KeychainManager.shared.hasOpenCodeAPIKey(providerID: providerID))
        XCTAssertTrue(KeychainManager.shared.hasAPIKey(provider: .miniMax))
    }

    func testLegacyAPIKeyCopyWritesOpenCodeNamespaceAndLeavesLegacyKey() throws {
        let providerID = "moonshot"
        defer {
            try? KeychainManager.shared.deleteAPIKey(provider: .moonshot)
            try? KeychainManager.shared.deleteOpenCodeAPIKey(providerID: providerID)
        }
        try? KeychainManager.shared.deleteAPIKey(provider: .moonshot)
        try? KeychainManager.shared.deleteOpenCodeAPIKey(providerID: providerID)

        try KeychainManager.shared.storeAPIKey("legacy-moonshot-key", provider: .moonshot)

        XCTAssertTrue(AIProviderCredentialMigration.canCopyLegacyAPIKeyForOpenCode(providerID: providerID))
        let copiedProvider = try AIProviderCredentialMigration.copyLegacyAPIKeyForOpenCode(providerID: providerID)

        XCTAssertEqual(copiedProvider, .moonshot)
        XCTAssertEqual(try KeychainManager.shared.retrieveOpenCodeAPIKey(providerID: providerID), "legacy-moonshot-key")
        XCTAssertEqual(try KeychainManager.shared.retrieveAPIKey(provider: .moonshot), "legacy-moonshot-key")
        XCTAssertFalse(AIProviderCredentialMigration.canCopyLegacyAPIKeyForOpenCode(providerID: providerID))
    }

    func testLegacyAPIKeyCopyIsUnavailableWithoutMatchingLegacyKey() throws {
        let providerID = "z.ai"
        defer {
            try? KeychainManager.shared.deleteAPIKey(provider: .zAI)
            try? KeychainManager.shared.deleteOpenCodeAPIKey(providerID: providerID)
        }
        try? KeychainManager.shared.deleteAPIKey(provider: .zAI)
        try? KeychainManager.shared.deleteOpenCodeAPIKey(providerID: providerID)

        XCTAssertFalse(AIProviderCredentialMigration.canCopyLegacyAPIKeyForOpenCode(providerID: providerID))
        XCTAssertThrowsError(try AIProviderCredentialMigration.copyLegacyAPIKeyForOpenCode(providerID: providerID)) { error in
            guard case KeychainManager.KeychainError.itemNotFound = error else {
                return XCTFail("Expected missing legacy key, got \(error)")
            }
        }
        XCTAssertFalse(KeychainManager.shared.hasOpenCodeAPIKey(providerID: providerID))
    }

    func testLegacyAPIKeyCopyIsUnavailableForUnmappedOpenCodeProvider() throws {
        let providerID = "openai"
        defer {
            try? KeychainManager.shared.deleteOpenCodeAPIKey(providerID: providerID)
        }
        try? KeychainManager.shared.deleteOpenCodeAPIKey(providerID: providerID)

        XCTAssertFalse(AIProviderCredentialMigration.canCopyLegacyAPIKeyForOpenCode(providerID: providerID))
        XCTAssertThrowsError(try AIProviderCredentialMigration.copyLegacyAPIKeyForOpenCode(providerID: providerID)) { error in
            guard case KeychainManager.KeychainError.itemNotFound = error else {
                return XCTFail("Expected unmapped provider to be unavailable, got \(error)")
            }
        }
    }

    func testLegacyAuthTokenIsNotCopiedToOpenCodeCredentials() throws {
        let providerID = "anthropic"
        defer {
            try? KeychainManager.shared.deleteAuthToken()
            try? KeychainManager.shared.deleteAPIKey(provider: .anthropic)
            try? KeychainManager.shared.deleteOpenCodeAPIKey(providerID: providerID)
        }
        try? KeychainManager.shared.deleteAuthToken()
        try? KeychainManager.shared.deleteAPIKey(provider: .anthropic)
        try? KeychainManager.shared.deleteOpenCodeAPIKey(providerID: providerID)

        try KeychainManager.shared.storeAuthToken("legacy-oauth-token")

        XCTAssertFalse(AIProviderCredentialMigration.canCopyLegacyAPIKeyForOpenCode(providerID: providerID))
        XCTAssertThrowsError(try AIProviderCredentialMigration.copyLegacyAPIKeyForOpenCode(providerID: providerID))
        XCTAssertEqual(try KeychainManager.shared.retrieveAuthToken(), "legacy-oauth-token")
        XCTAssertFalse(KeychainManager.shared.hasOpenCodeAPIKey(providerID: providerID))
    }

    func testLegacyAPIKeyCopyDoesNotOverwriteExistingOpenCodeKey() throws {
        let providerID = "anthropic"
        defer {
            try? KeychainManager.shared.deleteAPIKey(provider: .anthropic)
            try? KeychainManager.shared.deleteOpenCodeAPIKey(providerID: providerID)
        }
        try? KeychainManager.shared.deleteAPIKey(provider: .anthropic)
        try? KeychainManager.shared.deleteOpenCodeAPIKey(providerID: providerID)

        try KeychainManager.shared.storeAPIKey("legacy-anthropic-key", provider: .anthropic)
        try KeychainManager.shared.storeOpenCodeAPIKey("opencode-anthropic-key", providerID: providerID)

        XCTAssertFalse(AIProviderCredentialMigration.canCopyLegacyAPIKeyForOpenCode(providerID: providerID))
        XCTAssertThrowsError(try AIProviderCredentialMigration.copyLegacyAPIKeyForOpenCode(providerID: providerID))
        XCTAssertEqual(try KeychainManager.shared.retrieveOpenCodeAPIKey(providerID: providerID), "opencode-anthropic-key")
        XCTAssertEqual(try KeychainManager.shared.retrieveAPIKey(provider: .anthropic), "legacy-anthropic-key")
    }
}
