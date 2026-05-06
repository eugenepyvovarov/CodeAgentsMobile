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
            modelName: "Claude Sonnet",
            npmPackage: "@ai-sdk/openai"
        )

        let output = try document.toJSONString()
        let decoded = try OpenCodeMCPConfigDocument(jsonString: output)
        let providers = try XCTUnwrap(decoded.root["provider"] as? [String: Any])
        let openRouter = try XCTUnwrap(providers["openrouter"] as? [String: Any])
        let options = try XCTUnwrap(openRouter["options"] as? [String: Any])
        let models = try XCTUnwrap(openRouter["models"] as? [String: Any])

        XCTAssertEqual(openRouter["npm"] as? String, "@ai-sdk/openai")
        XCTAssertEqual(openRouter["name"] as? String, "OpenRouter")
        XCTAssertEqual(options["baseURL"] as? String, "https://openrouter.ai/api/v1")
        XCTAssertNil(options["apiKey"])
        XCTAssertNotNil(models["anthropic/claude-3.5-sonnet"])
    }

    func testOpenCodeAIProviderSettingsStoreUsesGlobalAndServerOverrides() throws {
        let suiteName = "OpenCodeAIProviderSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenCodeAIProviderSettingsStore(userDefaults: defaults)
        let serverID = UUID()

        try store.saveGlobalProfile(OpenCodeAIProviderProfile(
            providerID: "OpenAI",
            providerName: "OpenAI",
            authMode: .openAIChatGPT,
            modelID: "openai/gpt-5.2"
        ))

        XCTAssertEqual(store.effectiveProfile(for: serverID).normalizedProviderID, "openai")
        XCTAssertEqual(store.effectiveProfile(for: serverID).authMode, .openAIChatGPT)
        XCTAssertEqual(store.effectiveProfile(for: serverID).resolvedModelID, "openai/gpt-5.2")

        try store.saveServerOverride(
            OpenCodeServerAIProviderOverride(
                usesGlobalDefaults: false,
                profile: OpenCodeAIProviderProfile(
                    providerID: "openrouter",
                    providerName: "OpenRouter",
                    authMode: .apiKey,
                    modelID: "openrouter/anthropic/claude-sonnet"
                )
            ),
            for: serverID
        )

        XCTAssertEqual(store.effectiveProfile(for: serverID).normalizedProviderID, "openrouter")
        XCTAssertEqual(store.effectiveProfile(for: serverID).authMode, .apiKey)
        XCTAssertEqual(store.effectiveProfile(for: serverID).resolvedModelID, "openrouter/anthropic/claude-sonnet")
    }

    func testOpenCodeAIProviderProfileInfersCustomProviderModel() {
        let profile = OpenCodeAIProviderProfile(
            providerID: "local-ai",
            providerName: "Local AI",
            authMode: .apiKey,
            customBaseURL: "http://127.0.0.1:1234/v1",
            customModelID: "qwen3-coder",
            customModelName: "Qwen Coder"
        )

        XCTAssertTrue(profile.isCustomProvider)
        XCTAssertTrue(profile.isReadyToSave)
        XCTAssertEqual(profile.resolvedModelID, "local-ai/qwen3-coder")
        XCTAssertEqual(profile.resolvedSmallModelID, "local-ai/qwen3-coder")
    }

    func testDocumentWritesMiniMaxProviderWithoutAPIKey() throws {
        var document = OpenCodeMCPConfigDocument()

        document.setMiniMaxProvider()

        let output = try document.toJSONString()
        let decoded = try OpenCodeMCPConfigDocument(jsonString: output)
        let providers = try XCTUnwrap(decoded.root["provider"] as? [String: Any])
        let miniMax = try XCTUnwrap(providers["minimax"] as? [String: Any])
        let options = try XCTUnwrap(miniMax["options"] as? [String: Any])
        let models = try XCTUnwrap(miniMax["models"] as? [String: Any])

        XCTAssertEqual(miniMax["npm"] as? String, "@ai-sdk/anthropic")
        XCTAssertEqual(options["baseURL"] as? String, "https://api.minimax.io/anthropic/v1")
        XCTAssertNil(options["apiKey"])
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
