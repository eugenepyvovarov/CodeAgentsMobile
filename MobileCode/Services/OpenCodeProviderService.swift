//
//  OpenCodeProviderService.swift
//  CodeAgentsMobile
//
//  Purpose: OpenCode provider/auth status and credential sync
//

import Foundation

struct OpenCodeProviderStatus: Equatable {
    let providers: [OpenCodeProvider]
    let defaultModels: [String: String]
    let connectedProviderIDs: [String]
    let authMethods: [String: [OpenCodeProviderAuthMethod]]
}

@MainActor
final class OpenCodeProviderService: ObservableObject {
    static let shared = OpenCodeProviderService()

    private let sshService: SSHService
    private let client: OpenCodeClient

    init(sshService: SSHService? = nil, client: OpenCodeClient = OpenCodeClient()) {
        self.sshService = sshService ?? ServiceManager.shared.sshService
        self.client = client
    }

    func status(for project: RemoteProject) async throws -> OpenCodeProviderStatus {
        let session = try await sshService.getConnection(for: project, purpose: .opencode)
        let resolvedProviders = try await client.providerList(sshSession: session, directory: project.path)
        let resolvedAuthMethods = try await client.providerAuthMethods(sshSession: session, directory: project.path)

        return OpenCodeProviderStatus(
            providers: resolvedProviders.all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            defaultModels: resolvedProviders.defaultModels,
            connectedProviderIDs: resolvedProviders.connected.sorted(),
            authMethods: resolvedAuthMethods
        )
    }

    func saveAPIKey(_ apiKey: String, providerID: String, for project: RemoteProject) async throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedProviderID.isEmpty else {
            throw OpenCodeProviderServiceError.invalidInput
        }

        try KeychainManager.shared.storeOpenCodeAPIKey(trimmedKey, providerID: trimmedProviderID)

        let session = try await sshService.getConnection(for: project, purpose: .opencode)
        _ = try await client.setProviderAPIKey(
            sshSession: session,
            providerID: trimmedProviderID,
            apiKey: trimmedKey,
            directory: project.path
        )
    }
}

enum OpenCodeProviderServiceError: LocalizedError {
    case invalidInput

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Provider ID and API key are required."
        }
    }
}
