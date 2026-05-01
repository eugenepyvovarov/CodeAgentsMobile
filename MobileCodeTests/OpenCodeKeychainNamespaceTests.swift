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

    func testLegacyClaudeProviderMappingForOpenCodeFallback() {
        XCTAssertEqual(KeychainManager.legacyClaudeProvider(forOpenCodeProviderID: "anthropic"), .anthropic)
        XCTAssertEqual(KeychainManager.legacyClaudeProvider(forOpenCodeProviderID: "z.ai"), .zAI)
        XCTAssertEqual(KeychainManager.legacyClaudeProvider(forOpenCodeProviderID: "minimax"), .miniMax)
        XCTAssertEqual(KeychainManager.legacyClaudeProvider(forOpenCodeProviderID: "moonshot"), .moonshot)
        XCTAssertNil(KeychainManager.legacyClaudeProvider(forOpenCodeProviderID: "openai"))
    }
}
