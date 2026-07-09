//
//  OpenCodeProviderAPI.swift
//  CodeAgentsMobile
//
//  Purpose: Typed OpenCode provider and auth endpoints
//

import Foundation

extension OpenCodeClient {
    func providerList(
        sshSession: SSHSession,
        directory: String? = nil
    ) async throws -> OpenCodeProviderListResponse {
        try await jsonRequest(
            session: sshSession,
            method: .get,
            path: OpenCodeSessionPath.path("/provider", directory: directory),
            responseType: OpenCodeProviderListResponse.self
        )
    }

    func providerAuthMethods(
        sshSession: SSHSession,
        directory: String? = nil
    ) async throws -> [String: [OpenCodeProviderAuthMethod]] {
        try await jsonRequest(
            session: sshSession,
            method: .get,
            path: OpenCodeSessionPath.path("/provider/auth", directory: directory),
            responseType: [String: [OpenCodeProviderAuthMethod]].self
        )
    }

    func configuredProviders(
        sshSession: SSHSession,
        directory: String? = nil
    ) async throws -> OpenCodeConfiguredProvidersResponse {
        try await jsonRequest(
            session: sshSession,
            method: .get,
            path: OpenCodeSessionPath.path("/config/providers", directory: directory),
            responseType: OpenCodeConfiguredProvidersResponse.self
        )
    }

    @discardableResult
    func patchConfiguration(
        sshSession: SSHSession,
        json: String,
        directory: String? = nil
    ) async throws -> OpenCodeHTTPResponse {
        try await request(
            session: sshSession,
            method: .patch,
            path: OpenCodeSessionPath.path("/config", directory: directory),
            body: json
        )
    }

    func setProviderAPIKey(
        sshSession: SSHSession,
        providerID: String,
        apiKey: String,
        directory: String? = nil
    ) async throws -> Bool {
        try await jsonRequest(
            session: sshSession,
            method: .put,
            path: OpenCodeSessionPath.path("/auth/\(OpenCodeSessionPath.escape(providerID))", directory: directory),
            body: OpenCodeSessionJSON.encode(OpenCodeAPIAuthPayload(key: apiKey)),
            responseType: Bool.self
        )
    }

    func removeProviderAuth(
        sshSession: SSHSession,
        providerID: String,
        directory: String? = nil
    ) async throws -> Bool {
        try await jsonRequest(
            session: sshSession,
            method: .delete,
            path: OpenCodeSessionPath.path("/auth/\(OpenCodeSessionPath.escape(providerID))", directory: directory),
            responseType: Bool.self
        )
    }

    func startProviderOAuth(
        sshSession: SSHSession,
        providerID: String,
        methodIndex: Int,
        inputs: [String: String] = [:],
        directory: String? = nil
    ) async throws -> OpenCodeProviderOAuthAuthorization {
        try await jsonRequest(
            session: sshSession,
            method: .post,
            path: OpenCodeSessionPath.path(
                "/provider/\(OpenCodeSessionPath.escape(providerID))/oauth/authorize",
                directory: directory
            ),
            body: OpenCodeSessionJSON.encode(OpenCodeProviderOAuthAuthorizePayload(
                method: methodIndex,
                inputs: inputs.isEmpty ? nil : inputs
            )),
            responseType: OpenCodeProviderOAuthAuthorization.self
        )
    }

    func completeProviderOAuth(
        sshSession: SSHSession,
        providerID: String,
        methodIndex: Int,
        code: String? = nil,
        directory: String? = nil
    ) async throws -> Bool {
        try await jsonRequest(
            session: sshSession,
            method: .post,
            path: OpenCodeSessionPath.path(
                "/provider/\(OpenCodeSessionPath.escape(providerID))/oauth/callback",
                directory: directory
            ),
            body: OpenCodeSessionJSON.encode(OpenCodeProviderOAuthCallbackPayload(
                method: methodIndex,
                code: code?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )),
            responseType: Bool.self
        )
    }
}

struct OpenCodeConfiguredProvidersResponse: Decodable, Equatable {
    let providers: [OpenCodeProvider]
    let defaultModels: [String: String]

    enum CodingKeys: String, CodingKey {
        case providers
        case defaultModels = "default"
    }
}

struct OpenCodeProviderListResponse: Decodable, Equatable {
    let all: [OpenCodeProvider]
    let defaultModels: [String: String]
    let connected: [String]

    enum CodingKeys: String, CodingKey {
        case all
        case defaultModels = "default"
        case connected
    }
}

struct OpenCodeProvider: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let source: String?
    let env: [String]
    let key: String?
    let npm: String?
    let models: [String: OpenCodeProviderModel]

    init(
        id: String,
        name: String,
        source: String? = nil,
        env: [String] = [],
        key: String? = nil,
        npm: String? = nil,
        models: [String: OpenCodeProviderModel]
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.env = env
        self.key = key
        self.npm = npm
        self.models = models
    }

    var requiresExplicitConfiguration: Bool {
        source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "custom"
            && id.caseInsensitiveCompare("opencode") != .orderedSame
    }
}

struct OpenCodeProviderModel: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let api: OpenCodeProviderModelAPI?
    let reasoning: Bool?
    let reasoningOptions: [OpenCodeReasoningOption]?
    let toolCall: Bool?
    let temperature: Bool?
    let status: String?
    let modalities: OpenCodeModelModalities?
    let variants: [String: OpenCodeModelVariantConfig]?

    init(
        id: String,
        name: String,
        api: OpenCodeProviderModelAPI? = nil,
        reasoning: Bool? = nil,
        reasoningOptions: [OpenCodeReasoningOption]? = nil,
        toolCall: Bool? = nil,
        temperature: Bool? = nil,
        status: String? = nil,
        modalities: OpenCodeModelModalities? = nil,
        variants: [String: OpenCodeModelVariantConfig]? = nil
    ) {
        self.id = id
        self.name = name
        self.api = api
        self.reasoning = reasoning
        self.reasoningOptions = reasoningOptions
        self.toolCall = toolCall
        self.temperature = temperature
        self.status = status
        self.modalities = modalities
        self.variants = variants
    }

    enum CodingKeys: String, CodingKey {
        case id, name, api, reasoning, temperature, status, modalities, variants
        case reasoningOptions = "reasoning_options"
        case toolCall = "tool_call"
    }

    /// True when the model is suitable for agentic chat (tools + text). Unknown metadata keeps the model.
    var isChatCapable: Bool {
        if let toolCall, !toolCall {
            // Explicitly non-tool models are usually embeddings / TTS / image-only.
            if let outputs = modalities?.output, !outputs.isEmpty, !outputs.contains(where: { $0.caseInsensitiveCompare("text") == .orderedSame }) {
                return false
            }
            if let inputs = modalities?.input, inputs.count == 1, inputs[0].caseInsensitiveCompare("text") == .orderedSame,
               modalities?.output?.contains(where: { $0.caseInsensitiveCompare("text") == .orderedSame }) != true {
                return false
            }
            // tool_call:false with text output can still be chat — keep unless clearly non-text.
            if let outputs = modalities?.output, outputs.contains(where: { $0.caseInsensitiveCompare("text") == .orderedSame }) {
                return true
            }
            // No modalities: treat pure non-tool as non-chat (embeddings etc.)
            if modalities == nil {
                let lowered = "\(id) \(name)".lowercased()
                if lowered.contains("embed") || lowered.contains("tts") || lowered.contains("whisper") || lowered.contains("audio") {
                    return false
                }
            }
        }
        if let outputs = modalities?.output, !outputs.isEmpty,
           !outputs.contains(where: { $0.caseInsensitiveCompare("text") == .orderedSame }) {
            return false
        }
        return true
    }

    var isDeprecated: Bool {
        status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "deprecated"
    }

    var supportsReasoning: Bool {
        if reasoning == true { return true }
        if let options = reasoningOptions, !options.isEmpty { return true }
        if let variants, !variants.isEmpty { return true }
        return false
    }

    /// Effort / variant keys advertised for this model (excluding disabled variants).
    var effortLevels: [String] {
        var levels: [String] = []
        var seen = Set<String>()
        var disabled = Set<String>()

        if let variants {
            for (key, config) in variants where config.disabled == true {
                let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !normalized.isEmpty {
                    disabled.insert(normalized)
                }
            }
        }

        func append(_ raw: String) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            let key = value.lowercased()
            guard !seen.contains(key), !disabled.contains(key) else { return }
            seen.insert(key)
            levels.append(value)
        }

        for option in reasoningOptions ?? [] {
            let type = option.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if type == "effort" || type == "toggle" {
                for value in option.values ?? [] {
                    append(value)
                }
            }
        }

        if let variants {
            for (key, config) in variants.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
                if config.disabled == true { continue }
                append(key)
            }
        }

        return levels
    }
}

struct OpenCodeReasoningOption: Codable, Equatable {
    let type: String
    let values: [String]?
    let min: Int?

    init(type: String, values: [String]? = nil, min: Int? = nil) {
        self.type = type
        self.values = values
        self.min = min
    }
}

struct OpenCodeModelModalities: Codable, Equatable {
    let input: [String]?
    let output: [String]?
}

struct OpenCodeModelVariantConfig: Codable, Equatable {
    let disabled: Bool?

    init(disabled: Bool? = nil) {
        self.disabled = disabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled)
        // Accept arbitrary extra option fields without failing decode.
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(disabled, forKey: .disabled)
    }

    private enum CodingKeys: String, CodingKey {
        case disabled
    }
}

struct OpenCodeProviderModelAPI: Codable, Equatable {
    let id: String?
    let url: String?
    let npm: String?
}

struct OpenCodeProviderAuthMethod: Codable, Equatable {
    let type: String
    let label: String
    let prompts: [OpenCodeProviderAuthPrompt]?

    init(type: String, label: String, prompts: [OpenCodeProviderAuthPrompt]? = nil) {
        self.type = type
        self.label = label
        self.prompts = prompts
    }

    var isAPIKeyBased: Bool {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedType == "api"
            || normalizedType == "api_key"
            || normalizedType == "apikey"
            || normalizedType == "key"
            || normalizedLabel.contains("api key")
            || normalizedLabel.contains("personal access token")
            || normalizedLabel.contains("model access key")
    }

    var isOAuthBased: Bool {
        type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "oauth"
    }

    /// Device-code / remote-server friendly flows (preferred over localhost browser OAuth).
    var isHeadlessPreferred: Bool {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return label.contains("headless")
            || label.contains("device")
            || label.contains("remote")
            || label.contains("vps")
    }

    /// Browser OAuth that typically needs a local callback on the OpenCode host.
    var isBrowserLocalhostLikely: Bool {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !isHeadlessPreferred else { return false }
        return label.contains("browser")
            || label.contains("external browser")
    }

    var shortDisplayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "OAuth" : trimmed
    }
}

enum OpenCodeProviderOAuthMethodSelection {
    /// Prefer headless/device flows for remote SSH servers; fall back to any OAuth method.
    static func preferred(
        in methods: [OpenCodeProviderAuthMethod]
    ) -> (index: Int, method: OpenCodeProviderAuthMethod)? {
        let oauthMethods = methods.enumerated().filter { $0.element.isOAuthBased }
        guard !oauthMethods.isEmpty else { return nil }

        if let headless = oauthMethods.first(where: { $0.element.isHeadlessPreferred }) {
            return (headless.offset, headless.element)
        }

        if let nonBrowser = oauthMethods.first(where: { !$0.element.isBrowserLocalhostLikely }) {
            return (nonBrowser.offset, nonBrowser.element)
        }

        let first = oauthMethods[0]
        return (first.offset, first.element)
    }
}

struct OpenCodeProviderAuthPrompt: Codable, Equatable, Identifiable {
    let type: String
    let key: String
    let message: String
    let placeholder: String?
    let options: [OpenCodeProviderAuthPromptOption]?

    var id: String { key }
}

struct OpenCodeProviderAuthPromptOption: Codable, Equatable {
    let value: String
    let label: String
}

struct OpenCodeProviderOAuthAuthorization: Decodable, Equatable {
    let url: String
    let method: String
    let instructions: String

    var isCodeBased: Bool {
        method.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "code"
    }

    var isAutoBased: Bool {
        method.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "auto"
    }
}

private struct OpenCodeAPIAuthPayload: Encodable {
    let type = "api"
    let key: String
}

private struct OpenCodeProviderOAuthAuthorizePayload: Encodable {
    let method: Int
    let inputs: [String: String]?
}

private struct OpenCodeProviderOAuthCallbackPayload: Encodable {
    let method: Int
    let code: String?
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
