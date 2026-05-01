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
    let models: [String: OpenCodeProviderModel]
}

struct OpenCodeProviderModel: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
}

struct OpenCodeProviderAuthMethod: Decodable, Equatable {
    let type: String
    let label: String
}

private struct OpenCodeAPIAuthPayload: Encodable {
    let type = "api"
    let key: String
}
