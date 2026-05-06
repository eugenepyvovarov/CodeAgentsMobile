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

struct OpenCodeProvider: Decodable, Equatable, Identifiable {
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

struct OpenCodeProviderModel: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let api: OpenCodeProviderModelAPI?

    init(id: String, name: String, api: OpenCodeProviderModelAPI? = nil) {
        self.id = id
        self.name = name
        self.api = api
    }
}

struct OpenCodeProviderModelAPI: Decodable, Equatable {
    let id: String?
    let url: String?
    let npm: String?
}

struct OpenCodeProviderAuthMethod: Decodable, Equatable {
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
            || normalizedLabel.contains("api key")
    }

    var isOAuthBased: Bool {
        type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "oauth"
    }
}

struct OpenCodeProviderAuthPrompt: Decodable, Equatable, Identifiable {
    let type: String
    let key: String
    let message: String
    let placeholder: String?
    let options: [OpenCodeProviderAuthPromptOption]?

    var id: String { key }
}

struct OpenCodeProviderAuthPromptOption: Decodable, Equatable {
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
