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

    func testProviderAuthMethodDetectsOAuthAndAPIKeyTypes() throws {
        let json = """
        [
          { "type": "oauth", "label": "ChatGPT Pro/Plus (headless)" },
          { "type": "api", "label": "Manually enter API Key" }
        ]
        """

        let methods = try JSONDecoder().decode([OpenCodeProviderAuthMethod].self, from: Data(json.utf8))

        XCTAssertTrue(methods[0].isOAuthBased)
        XCTAssertFalse(methods[0].isAPIKeyBased)
        XCTAssertFalse(methods[1].isOAuthBased)
        XCTAssertTrue(methods[1].isAPIKeyBased)
    }

    func testProviderOAuthAuthorizationDecodesHeadlessDeviceFlow() throws {
        let json = """
        {
          "url": "https://auth.openai.com/codex/device",
          "method": "auto",
          "instructions": "Enter code: ABCD-EFGH"
        }
        """

        let authorization = try JSONDecoder().decode(OpenCodeProviderOAuthAuthorization.self, from: Data(json.utf8))

        XCTAssertEqual(authorization.url, "https://auth.openai.com/codex/device")
        XCTAssertTrue(authorization.isAutoBased)
        XCTAssertFalse(authorization.isCodeBased)
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

    func testProviderStatusUsesConfiguredModelsWhenAvailable() {
        let catalogOpenAI = OpenCodeProvider(
            id: "openai",
            name: "OpenAI",
            source: nil,
            env: [],
            key: nil,
            models: [
                "gpt-5.4-mini": OpenCodeProviderModel(id: "gpt-5.4-mini", name: "GPT-5.4 Mini"),
                "gpt-5.5": OpenCodeProviderModel(id: "gpt-5.5", name: "GPT-5.5")
            ]
        )
        let configuredOpenAI = OpenCodeProvider(
            id: "openai",
            name: "OpenAI",
            source: nil,
            env: [],
            key: nil,
            models: [
                "gpt-5.5": OpenCodeProviderModel(id: "gpt-5.5", name: "GPT-5.5")
            ]
        )
        let status = OpenCodeProviderStatus(
            providers: [catalogOpenAI],
            configuredProviders: [configuredOpenAI],
            defaultModels: [:],
            connectedProviderIDs: ["openai"],
            authMethods: [:]
        )

        XCTAssertEqual(status.modelChoices(for: "openai").map(\.id), ["openai/gpt-5.5"])
        XCTAssertFalse(status.hasModel(providerID: "openai", modelID: "gpt-5.4-mini"))
    }

    func testProviderStatusSeparatesConfiguredProviderFromAuthCredential() {
        let openAI = OpenCodeProvider(
            id: "openai",
            name: "OpenAI",
            source: "config",
            models: ["gpt-5.5": OpenCodeProviderModel(id: "gpt-5.5", name: "GPT-5.5")]
        )
        let status = OpenCodeProviderStatus(
            providers: [openAI],
            defaultModels: [:],
            connectedProviderIDs: ["openai"],
            authenticatedProviderIDs: [],
            authMethods: ["openai": [OpenCodeProviderAuthMethod(type: "oauth", label: "ChatGPT Pro/Plus")]]
        )

        XCTAssertEqual(status.connectedProviderIDs, ["openai"])
        XCTAssertFalse(status.isAuthenticated(providerID: "openai"))
    }

    func testProviderStatusReportsAuthenticatedProviderCaseInsensitively() {
        let status = OpenCodeProviderStatus(
            providers: [],
            defaultModels: [:],
            connectedProviderIDs: [],
            authenticatedProviderIDs: ["OpenAI"],
            authMethods: [:]
        )

        XCTAssertTrue(status.isAuthenticated(providerID: "openai"))
    }

    func testProviderStatusSortsModelsByRawID() {
        let provider = OpenCodeProvider(
            id: "openai",
            name: "OpenAI",
            source: nil,
            env: [],
            key: nil,
            models: [
                "z-model": OpenCodeProviderModel(id: "z-model", name: "A Display Name"),
                "a-model": OpenCodeProviderModel(id: "a-model", name: "Z Display Name")
            ]
        )
        let status = OpenCodeProviderStatus(
            providers: [provider],
            defaultModels: [:],
            connectedProviderIDs: [],
            authMethods: [:]
        )

        XCTAssertEqual(status.modelChoices(for: "openai").map(\.id), ["openai/a-model", "openai/z-model"])
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

    func testProviderConnectionDefaultsSkipUnavailableDefaultModel() {
        let openAI = OpenCodeProvider(
            id: "openai",
            name: "OpenAI",
            source: nil,
            env: [],
            key: nil,
            models: [
                "gpt-5.5": OpenCodeProviderModel(id: "gpt-5.5", name: "GPT-5.5")
            ]
        )
        let status = OpenCodeProviderStatus(
            providers: [openAI],
            configuredProviders: [openAI],
            defaultModels: ["openai": "gpt-5.4-mini"],
            connectedProviderIDs: ["openai"],
            authMethods: [:]
        )

        XCTAssertNil(OpenCodeProviderConnectionDefaults.suggestedModelID(providerID: "openai", status: status))
    }

    func testOpenCodeProviderProfileDoesNotRequireAPIKeyCredential() {
        let profile = OpenCodeAIProviderProfile(
            providerID: "opencode",
            providerName: "OpenCode Zen",
            authMode: .apiKey,
            modelID: "opencode/grok-code-fast-1"
        )

        XCTAssertFalse(profile.requiresAPIKeyCredential)
        XCTAssertTrue(profile.isReadyToSave)
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
        XCTAssertNotNil(models["MiniMax-M2.7-highspeed"])
    }

    func testDocumentWritesCatalogCustomProviderForMiniMaxCodingPlan() throws {
        var document = OpenCodeMCPConfigDocument()
        let provider = OpenCodeProvider(
            id: "minimax-coding-plan",
            name: "MiniMax Coding Plan (minimax.io)",
            source: "custom",
            env: ["MINIMAX_API_KEY"],
            key: nil,
            models: [
                "MiniMax-M2.7": OpenCodeProviderModel(
                    id: "MiniMax-M2.7",
                    name: "MiniMax-M2.7",
                    api: OpenCodeProviderModelAPI(
                        id: "MiniMax-M2.7",
                        url: "https://api.minimax.io/anthropic/v1",
                        npm: "@ai-sdk/anthropic"
                    )
                ),
                "MiniMax-M2.7-highspeed": OpenCodeProviderModel(
                    id: "MiniMax-M2.7-highspeed",
                    name: "MiniMax-M2.7-highspeed",
                    api: OpenCodeProviderModelAPI(
                        id: "MiniMax-M2.7-highspeed",
                        url: "https://api.minimax.io/anthropic/v1",
                        npm: "@ai-sdk/anthropic"
                    )
                )
            ]
        )

        try document.setCatalogProvider(provider, preferredModelID: "MiniMax-M2.7")

        let decoded = try OpenCodeMCPConfigDocument(jsonString: document.toJSONString())
        let providers = try XCTUnwrap(decoded.root["provider"] as? [String: Any])
        let miniMax = try XCTUnwrap(providers["minimax-coding-plan"] as? [String: Any])
        let options = try XCTUnwrap(miniMax["options"] as? [String: Any])
        let models = try XCTUnwrap(miniMax["models"] as? [String: Any])

        XCTAssertEqual(miniMax["npm"] as? String, "@ai-sdk/anthropic")
        XCTAssertEqual(miniMax["name"] as? String, "MiniMax Coding Plan (minimax.io)")
        XCTAssertEqual(options["baseURL"] as? String, "https://api.minimax.io/anthropic/v1")
        XCTAssertNotNil(models["MiniMax-M2.7"])
        XCTAssertNotNil(models["MiniMax-M2.7-highspeed"])
    }

    func testDocumentWritesCatalogProviderWithoutExplicitBaseURL() throws {
        var document = OpenCodeMCPConfigDocument()
        let provider = OpenCodeProvider(
            id: "openai",
            name: "OpenAI",
            source: "custom",
            env: ["OPENAI_API_KEY"],
            key: nil,
            npm: "@ai-sdk/openai",
            models: [
                "gpt-5.5": OpenCodeProviderModel(
                    id: "gpt-5.5",
                    name: "GPT-5.5",
                    api: OpenCodeProviderModelAPI(
                        id: "gpt-5.5",
                        url: nil,
                        npm: nil
                    )
                )
            ]
        )

        try document.setCatalogProvider(provider, preferredModelID: "gpt-5.5")

        let decoded = try OpenCodeMCPConfigDocument(jsonString: document.toJSONString())
        let providers = try XCTUnwrap(decoded.root["provider"] as? [String: Any])
        let openAI = try XCTUnwrap(providers["openai"] as? [String: Any])
        let models = try XCTUnwrap(openAI["models"] as? [String: Any])

        XCTAssertEqual(openAI["npm"] as? String, "@ai-sdk/openai")
        XCTAssertEqual(openAI["name"] as? String, "OpenAI")
        XCTAssertNil(openAI["options"])
        XCTAssertNotNil(models["gpt-5.5"])
    }

    func testDocumentRemovesOpenAIProviderOverrideForBuiltInAuth() throws {
        var document = try OpenCodeMCPConfigDocument(jsonString: """
        {
          "$schema": "https://opencode.ai/config.json",
          "provider": {
            "minimax-coding-plan": {
              "npm": "@ai-sdk/anthropic",
              "name": "MiniMax Coding Plan",
              "models": { "MiniMax-M2.7": { "name": "MiniMax-M2.7" } }
            },
            "OpenAI": {
              "npm": "@ai-sdk/openai",
              "name": "OpenAI",
              "models": { "gpt-5.5": { "name": "GPT-5.5" } }
            }
          }
        }
        """)

        document.removeProviderConfiguration(id: "openai")

        let decoded = try OpenCodeMCPConfigDocument(jsonString: document.toJSONString())
        let providers = try XCTUnwrap(decoded.root["provider"] as? [String: Any])
        XCTAssertNil(providers["OpenAI"])
        XCTAssertNotNil(providers["minimax-coding-plan"])
    }

    func testOpenAIProviderProfileUsesBuiltInProviderWhenNotCustom() {
        let chatGPTProfile = OpenCodeAIProviderProfile(
            providerID: "OpenAI",
            providerName: "OpenAI",
            authMode: .openAIChatGPT,
            modelID: "openai/gpt-5.5"
        )

        let apiKeyProfile = OpenCodeAIProviderProfile(
            providerID: "openai",
            providerName: "OpenAI",
            authMode: .apiKey,
            modelID: "openai/gpt-5.5"
        )

        let customEndpointProfile = OpenCodeAIProviderProfile(
            providerID: "openai",
            providerName: "OpenAI",
            authMode: .apiKey,
            customBaseURL: "https://example.com/v1",
            customModelID: "custom-model"
        )

        XCTAssertTrue(chatGPTProfile.usesBuiltInOpenAIProvider)
        XCTAssertTrue(apiKeyProfile.usesBuiltInOpenAIProvider)
        XCTAssertFalse(customEndpointProfile.usesBuiltInOpenAIProvider)
    }

    func testPromptModelParsesFullID() throws {
        let model = try XCTUnwrap(OpenCodePromptModel(fullID: "anthropic/claude-sonnet"))

        XCTAssertEqual(model.providerID, "anthropic")
        XCTAssertEqual(model.modelID, "claude-sonnet")
        XCTAssertEqual(model.fullID, "anthropic/claude-sonnet")
        XCTAssertNil(OpenCodePromptModel(fullID: "missing-provider-separator"))
    }

    func testOpenCodeErrorDisplayExplainsMissingProviderModel() throws {
        let json = """
        {
          "name": "ProviderModelNotFoundError",
          "data": {
            "providerID": "minimax-coding-plan",
            "modelID": "MiniMax-M2.7"
          }
        }
        """

        let error = try JSONDecoder().decode(OpenCodeErrorInfo.self, from: Data(json.utf8))

        XCTAssertEqual(
            error.displayMessage,
            "OpenCode does not have minimax-coding-plan/MiniMax-M2.7 loaded. Apply the provider config and reload OpenCode."
        )
    }
}
