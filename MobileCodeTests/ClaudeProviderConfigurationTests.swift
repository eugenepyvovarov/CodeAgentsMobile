import XCTest
@testable import CodeAgentsMobile

final class ClaudeProviderConfigurationTests: XCTestCase {
    func testDefaultsIncludeAllProviders() throws {
        let config = ClaudeProviderConfiguration.defaults()
        XCTAssertEqual(config.selectedProvider, .anthropic)

        for provider in ClaudeModelProvider.allCases {
            XCTAssertNotNil(config.overridesByProvider[provider.rawValue])
        }
    }

    func testSaveAndLoadRoundTrip() throws {
        let suiteName = "ClaudeProviderConfigurationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }

        var config = ClaudeProviderConfiguration.defaults()
        config.selectedProvider = .zAI
        var overrides = config.overrides(for: .zAI)
        overrides.defaultSonnetModel = "GLM-4.6"
        config.setOverrides(overrides, for: .zAI)

        ClaudeProviderConfigurationStore.save(config, userDefaults: defaults)
        let loaded = ClaudeProviderConfigurationStore.load(userDefaults: defaults)

        XCTAssertEqual(loaded.selectedProvider, .zAI)
        XCTAssertEqual(loaded.overrides(for: .zAI).defaultSonnetModel, "GLM-4.6")
    }

    func testZaiDefaultsMatchExpectedBaseURL() throws {
        let overrides = ClaudeProviderOverrides.defaults(for: .zAI)
        XCTAssertEqual(overrides.baseURL, "https://api.z.ai/api/anthropic")
        XCTAssertEqual(overrides.defaultOpusModel, "GLM-4.7")
        XCTAssertEqual(overrides.defaultHaikuModel, "GLM-4.5-Air")
    }
}

