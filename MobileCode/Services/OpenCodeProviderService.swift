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

    var apiKeyProviders: [OpenCodeProvider] {
        providers.filter { provider in
            authMethods[provider.id]?.contains(where: { $0.isAPIKeyBased }) == true
        }
    }

    var apiKeyProviderChoices: [OpenCodeAPIKeyProviderChoice] {
        let discovered = apiKeyProviders.map { provider in
            OpenCodeAPIKeyProviderChoice(id: provider.id, name: provider.name)
        }
        return OpenCodeAPIKeyProviderChoice.merging(discovered, with: OpenCodeAPIKeyProviderChoice.preferred)
    }

    var modelChoices: [OpenCodeModelChoice] {
        providers.flatMap { provider in
            provider.models.values.map { model in
                OpenCodeModelChoice(
                    providerID: provider.id,
                    providerName: provider.name,
                    modelID: model.id,
                    modelName: model.name
                )
            }
        }
        .sorted { lhs, rhs in
            lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }
}

struct OpenCodeAPIKeyProviderChoice: Identifiable, Hashable {
    let id: String
    let name: String

    static let preferred: [OpenCodeAPIKeyProviderChoice] = [
        OpenCodeAPIKeyProviderChoice(id: "anthropic", name: "Anthropic"),
        OpenCodeAPIKeyProviderChoice(id: "openai", name: "OpenAI"),
        OpenCodeAPIKeyProviderChoice(id: "google", name: "Google"),
        OpenCodeAPIKeyProviderChoice(id: "xai", name: "xAI"),
        OpenCodeAPIKeyProviderChoice(id: "groq", name: "Groq"),
        OpenCodeAPIKeyProviderChoice(id: "openrouter", name: "OpenRouter"),
        OpenCodeAPIKeyProviderChoice(id: "minimax", name: "MiniMax")
    ]

    static func merging(
        _ discovered: [OpenCodeAPIKeyProviderChoice],
        with preferred: [OpenCodeAPIKeyProviderChoice]
    ) -> [OpenCodeAPIKeyProviderChoice] {
        var seen = Set<String>()
        var merged: [OpenCodeAPIKeyProviderChoice] = []

        for choice in discovered + preferred {
            let normalizedID = choice.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedID.isEmpty, !seen.contains(normalizedID) else { continue }
            seen.insert(normalizedID)
            merged.append(choice)
        }

        return merged
    }
}

enum OpenCodeProviderConnectionDefaults {
    static func suggestedModelID(providerID: String, status: OpenCodeProviderStatus?) -> String? {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProviderID.isEmpty else { return nil }

        if let defaultModel = status?.defaultModels.first(where: { key, _ in
            key.caseInsensitiveCompare(normalizedProviderID) == .orderedSame
        })?.value.nilIfEmpty {
            return "\(normalizedProviderID)/\(defaultModel)"
        }

        switch normalizedProviderID.lowercased() {
        case "minimax":
            return "minimax/MiniMax-M2.7"
        default:
            return nil
        }
    }

    static func suggestedSmallModelID(providerID: String, status: OpenCodeProviderStatus?) -> String? {
        suggestedModelID(providerID: providerID, status: status)
    }
}

struct OpenCodeModelChoice: Identifiable, Hashable {
    let providerID: String
    let providerName: String
    let modelID: String
    let modelName: String

    var id: String {
        "\(providerID)/\(modelID)"
    }

    var label: String {
        "\(providerName) · \(modelName)"
    }
}

enum OpenCodeConfigurationScope: String, CaseIterable, Identifiable {
    case global
    case project

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .global:
            return "Server Default"
        case .project:
            return "This Project"
        }
    }
}

struct OpenCodeModelConfiguration: Equatable {
    let scope: OpenCodeConfigurationScope
    let modelID: String?
    let smallModelID: String?
    let enabledProviderIDs: [String]
    let disabledProviderIDs: [String]
}

struct OpenCodeCustomProviderInput: Equatable {
    var id: String
    var name: String
    var baseURL: String
    var modelID: String
    var modelName: String
    var apiKey: String
}

@MainActor
final class OpenCodeProviderService: ObservableObject {
    static let shared = OpenCodeProviderService()

    private let sshService: SSHService
    private let clientOverride: OpenCodeClient?

    init(sshService: SSHService? = nil, client: OpenCodeClient? = nil) {
        self.sshService = sshService ?? ServiceManager.shared.sshService
        self.clientOverride = client
    }

    func status(for project: RemoteProject) async throws -> OpenCodeProviderStatus {
        let session = try await sshService.getConnection(for: project, purpose: .opencode)
        let client = client(for: project)
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

        if trimmedProviderID.caseInsensitiveCompare("minimax") == .orderedSame {
            try await saveMiniMaxAPIKeyToProjectConfiguration(trimmedKey, for: project)
            return
        }

        let session = try await sshService.getConnection(for: project, purpose: .opencode)
        let client = client(for: project)
        _ = try await client.setProviderAPIKey(
            sshSession: session,
            providerID: trimmedProviderID,
            apiKey: trimmedKey,
            directory: project.path
        )
    }

    func modelConfiguration(
        for project: RemoteProject,
        scope: OpenCodeConfigurationScope
    ) async throws -> OpenCodeModelConfiguration {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        let loaded = try await loadConfiguration(for: project, scope: scope, session: session)
        return OpenCodeModelConfiguration(
            scope: scope,
            modelID: loaded.document.selectedModelID,
            smallModelID: loaded.document.selectedSmallModelID,
            enabledProviderIDs: loaded.document.enabledProviderIDs,
            disabledProviderIDs: loaded.document.disabledProviderIDs
        )
    }

    func saveModelConfiguration(
        modelID: String?,
        smallModelID: String?,
        enabledProviderIDs: [String] = [],
        disabledProviderIDs: [String] = [],
        scope: OpenCodeConfigurationScope,
        for project: RemoteProject
    ) async throws {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        var loaded = try await loadConfiguration(for: project, scope: scope, session: session)
        loaded.document.setModelSelection(modelID: modelID, smallModelID: smallModelID)
        loaded.document.setProviderFilters(enabled: enabledProviderIDs, disabled: disabledProviderIDs)
        try await writeConfiguration(loaded.document, to: loaded.path, session: session)
    }

    func saveCustomOpenAICompatibleProvider(
        _ input: OpenCodeCustomProviderInput,
        scope: OpenCodeConfigurationScope,
        for project: RemoteProject
    ) async throws {
        let providerID = input.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = input.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerID.isEmpty,
              !input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !input.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !input.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.isEmpty else {
            throw OpenCodeProviderServiceError.invalidInput
        }

        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        var loaded = try await loadConfiguration(for: project, scope: scope, session: session)
        try loaded.document.setCustomOpenAICompatibleProvider(
            id: providerID,
            name: input.name,
            baseURL: input.baseURL,
            modelID: input.modelID,
            modelName: input.modelName,
            apiKey: apiKey
        )
        loaded.document.setModelSelection(modelID: "\(providerID)/\(input.modelID)", smallModelID: loaded.document.selectedSmallModelID)
        try await writeConfiguration(loaded.document, to: loaded.path, session: session)

        try KeychainManager.shared.storeOpenCodeAPIKey(apiKey, providerID: providerID)
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

private extension OpenCodeProviderService {
    func client(for project: RemoteProject) -> OpenCodeClient {
        clientOverride ?? OpenCodeClientFactory.client(for: project.serverId)
    }

    func loadConfiguration(
        for project: RemoteProject,
        scope: OpenCodeConfigurationScope,
        session: SSHSession
    ) async throws -> (path: String, document: OpenCodeMCPConfigDocument) {
        if scope == .global {
            let path = try await globalConfigurationPath(session: session)
            return (path, try await readConfiguration(at: path, session: session))
        }

        let jsonPath = "\(project.path)/opencode.json"
        if let document = try await readConfigurationIfPresent(at: jsonPath, session: session) {
            return (jsonPath, document)
        }

        let jsoncPath = "\(project.path)/opencode.jsonc"
        if let document = try await readConfigurationIfPresent(at: jsoncPath, session: session) {
            return (jsoncPath, document)
        }

        return (jsonPath, OpenCodeMCPConfigDocument())
    }

    func readConfiguration(at path: String, session: SSHSession) async throws -> OpenCodeMCPConfigDocument {
        if let document = try await readConfigurationIfPresent(at: path, session: session) {
            return document
        }
        return OpenCodeMCPConfigDocument()
    }

    func readConfigurationIfPresent(at path: String, session: SSHSession) async throws -> OpenCodeMCPConfigDocument? {
        do {
            return try OpenCodeMCPConfigDocument(jsonString: try await session.readFile(path))
        } catch {
            let errorMessage = error.localizedDescription.lowercased()
            if errorMessage.contains("no such file") || errorMessage.contains("cannot open") {
                return nil
            }
            throw error
        }
    }

    func writeConfiguration(
        _ document: OpenCodeMCPConfigDocument,
        to path: String,
        session: SSHSession
    ) async throws {
        guard let data = try document.toJSONString().data(using: .utf8) else {
            throw OpenCodeProviderServiceError.invalidInput
        }
        let base64 = data.base64EncodedString()
        let escapedPath = escapeForDoubleQuotes(path)
        let command = "mkdir -p \"$(dirname \"\(escapedPath)\")\" && printf '%s' '\(base64)' | base64 -d > \"\(escapedPath)\""
        _ = try await session.execute(command)
    }

    func globalConfigurationPath(session: SSHSession) async throws -> String {
        let command = "printf '%s' \"${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json\""
        let path = try await session.execute(command).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw OpenCodeProviderServiceError.invalidInput
        }
        return path
    }

    func escapeForDoubleQuotes(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    func saveMiniMaxAPIKeyToProjectConfiguration(_ apiKey: String, for project: RemoteProject) async throws {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        var loaded = try await loadConfiguration(for: project, scope: .project, session: session)
        try loaded.document.setMiniMaxProvider(apiKey: apiKey)
        if loaded.document.selectedModelID == nil {
            loaded.document.setModelSelection(
                modelID: "minimax/MiniMax-M2.7",
                smallModelID: loaded.document.selectedSmallModelID
            )
        }
        try await writeConfiguration(loaded.document, to: loaded.path, session: session)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
