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
    }

    func testOpenCodeServerPasswordRoundTripsByServerID() throws {
        let serverID = UUID()
        defer {
            try? KeychainManager.shared.deleteOpenCodeServerPassword(for: serverID)
        }

        try KeychainManager.shared.storeOpenCodeServerPassword("fixture_password", for: serverID)

        XCTAssertTrue(KeychainManager.shared.hasOpenCodeServerPassword(for: serverID))
        XCTAssertEqual(
            try KeychainManager.shared.retrieveOpenCodeServerPassword(for: serverID),
            "fixture_password"
        )
    }

    func testLegacyClaudeProviderMappingForOpenCodeFallback() {
        XCTAssertEqual(KeychainManager.legacyClaudeProvider(forOpenCodeProviderID: "anthropic"), .anthropic)
        XCTAssertEqual(KeychainManager.legacyClaudeProvider(forOpenCodeProviderID: "z.ai"), .zAI)
        XCTAssertEqual(KeychainManager.legacyClaudeProvider(forOpenCodeProviderID: "minimax"), .miniMax)
        XCTAssertEqual(KeychainManager.legacyClaudeProvider(forOpenCodeProviderID: "moonshot"), .moonshot)
        XCTAssertNil(KeychainManager.legacyClaudeProvider(forOpenCodeProviderID: "openai"))
    }
}
