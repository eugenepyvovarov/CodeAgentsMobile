import XCTest
@testable import CodeAgentsMobile

final class OpenCodeProviderModelConfigurationTests: XCTestCase {
    func testProviderStatusFiltersAPIKeyProviders() {
        let anthropic = OpenCodeProvider(
            id: "anthropic",
            name: "Anthropic",
            source: nil,
            env: [],
            key: nil,
            models: ["claude-sonnet": OpenCodeProviderModel(id: "claude-sonnet", name: "Claude Sonnet")]
        )
        let github = OpenCodeProvider(
            id: "github-copilot",
            name: "GitHub Copilot",
            source: nil,
            env: [],
            key: nil,
            models: [:]
        )
        let status = OpenCodeProviderStatus(
            providers: [anthropic, github],
            defaultModels: [:],
            connectedProviderIDs: [],
            authMethods: [
                "anthropic": [OpenCodeProviderAuthMethod(type: "api", label: "API Key")],
                "github-copilot": [OpenCodeProviderAuthMethod(type: "oauth", label: "Browser Login")]
            ]
        )

        XCTAssertEqual(status.apiKeyProviders.map(\.id), ["anthropic"])
        XCTAssertEqual(status.modelChoices.first?.id, "anthropic/claude-sonnet")
    }

    func testAPIKeyProviderChoicesIncludeMiniMaxFallback() {
        let anthropic = OpenCodeProvider(
            id: "anthropic",
            name: "Anthropic From OpenCode",
            source: nil,
            env: [],
            key: nil,
            models: [:]
        )
        let status = OpenCodeProviderStatus(
            providers: [anthropic],
            defaultModels: [:],
            connectedProviderIDs: [],
            authMethods: [
                "anthropic": [OpenCodeProviderAuthMethod(type: "api", label: "API Key")]
            ]
        )

        XCTAssertEqual(status.apiKeyProviderChoices.first?.name, "Anthropic From OpenCode")
        XCTAssertTrue(status.apiKeyProviderChoices.contains(OpenCodeAPIKeyProviderChoice(id: "minimax", name: "MiniMax")))
        XCTAssertEqual(status.apiKeyProviderChoices.filter { $0.id == "anthropic" }.count, 1)
    }

    func testProviderConnectionDefaultsUseOpenCodeDefaultModels() {
        let status = OpenCodeProviderStatus(
            providers: [],
            defaultModels: ["anthropic": "claude-sonnet-4-5"],
            connectedProviderIDs: [],
            authMethods: [:]
        )

        XCTAssertEqual(
            OpenCodeProviderConnectionDefaults.suggestedModelID(providerID: "anthropic", status: status),
            "anthropic/claude-sonnet-4-5"
        )
        XCTAssertEqual(
            OpenCodeProviderConnectionDefaults.suggestedSmallModelID(providerID: "anthropic", status: status),
            "anthropic/claude-sonnet-4-5"
        )
    }

    func testProviderConnectionDefaultsFallbackToMiniMaxM27() {
        XCTAssertEqual(
            OpenCodeProviderConnectionDefaults.suggestedModelID(providerID: "minimax", status: nil),
            "minimax/MiniMax-M2.7"
        )
        XCTAssertEqual(
            OpenCodeProviderConnectionDefaults.suggestedSmallModelID(providerID: "MiniMax", status: nil),
            "minimax/MiniMax-M2.7"
        )
        XCTAssertNil(OpenCodeProviderConnectionDefaults.suggestedModelID(providerID: "openai", status: nil))
    }

    func testDocumentWritesModelSelectionAndProviderFilters() throws {
        var document = try OpenCodeMCPConfigDocument(jsonString: #"{"formatter":false}"#)

        document.setModelSelection(modelID: "anthropic/claude-sonnet", smallModelID: "openai/gpt-4.1-mini")
        document.setProviderFilters(enabled: ["anthropic", "openai"], disabled: ["github-copilot"])

        let output = try document.toJSONString()
        let decoded = try OpenCodeMCPConfigDocument(jsonString: output)

        XCTAssertEqual(decoded.selectedModelID, "anthropic/claude-sonnet")
        XCTAssertEqual(decoded.selectedSmallModelID, "openai/gpt-4.1-mini")
        XCTAssertEqual(decoded.enabledProviderIDs, ["anthropic", "openai"])
        XCTAssertEqual(decoded.disabledProviderIDs, ["github-copilot"])
        XCTAssertEqual(decoded.root["formatter"] as? Bool, false)
    }

    func testDocumentWritesCustomOpenAICompatibleProvider() throws {
        var document = OpenCodeMCPConfigDocument()

        try document.setCustomOpenAICompatibleProvider(
            id: "openrouter",
            name: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            modelID: "anthropic/claude-3.5-sonnet",
            modelName: "Claude Sonnet"
        )

        let output = try document.toJSONString()
        let decoded = try OpenCodeMCPConfigDocument(jsonString: output)
        let providers = try XCTUnwrap(decoded.root["provider"] as? [String: Any])
        let openRouter = try XCTUnwrap(providers["openrouter"] as? [String: Any])
        let options = try XCTUnwrap(openRouter["options"] as? [String: Any])
        let models = try XCTUnwrap(openRouter["models"] as? [String: Any])

        XCTAssertEqual(openRouter["npm"] as? String, "@ai-sdk/openai-compatible")
        XCTAssertEqual(openRouter["name"] as? String, "OpenRouter")
        XCTAssertEqual(options["baseURL"] as? String, "https://openrouter.ai/api/v1")
        XCTAssertNotNil(models["anthropic/claude-3.5-sonnet"])
    }

    func testDocumentWritesMiniMaxProviderWithAPIKey() throws {
        var document = OpenCodeMCPConfigDocument()

        try document.setMiniMaxProvider(apiKey: "test-minimax-key")

        let output = try document.toJSONString()
        let decoded = try OpenCodeMCPConfigDocument(jsonString: output)
        let providers = try XCTUnwrap(decoded.root["provider"] as? [String: Any])
        let miniMax = try XCTUnwrap(providers["minimax"] as? [String: Any])
        let options = try XCTUnwrap(miniMax["options"] as? [String: Any])
        let models = try XCTUnwrap(miniMax["models"] as? [String: Any])

        XCTAssertEqual(miniMax["npm"] as? String, "@ai-sdk/anthropic")
        XCTAssertEqual(options["baseURL"] as? String, "https://api.minimax.io/anthropic/v1")
        XCTAssertEqual(options["apiKey"] as? String, "test-minimax-key")
        XCTAssertNotNil(models["MiniMax-M2.7"])
    }

    func testPromptModelParsesFullID() throws {
        let model = try XCTUnwrap(OpenCodePromptModel(fullID: "anthropic/claude-sonnet"))

        XCTAssertEqual(model.providerID, "anthropic")
        XCTAssertEqual(model.modelID, "claude-sonnet")
        XCTAssertEqual(model.fullID, "anthropic/claude-sonnet")
        XCTAssertNil(OpenCodePromptModel(fullID: "missing-provider-separator"))
    }
}
