//
//  OpenCodeProviderService.swift
//  CodeAgentsMobile
//
//  Purpose: OpenCode provider/auth status and credential sync
//

import Foundation

struct OpenCodeProviderStatus: Equatable {
    let providers: [OpenCodeProvider]
    let configuredProviders: [OpenCodeProvider]
    let defaultModels: [String: String]
    let connectedProviderIDs: [String]
    let authMethods: [String: [OpenCodeProviderAuthMethod]]

    init(
        providers: [OpenCodeProvider],
        configuredProviders: [OpenCodeProvider] = [],
        defaultModels: [String: String],
        connectedProviderIDs: [String],
        authMethods: [String: [OpenCodeProviderAuthMethod]]
    ) {
        self.providers = providers
        self.configuredProviders = configuredProviders
        self.defaultModels = defaultModels
        self.connectedProviderIDs = connectedProviderIDs
        self.authMethods = authMethods
    }

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
            modelChoices(from: provider)
        }
        .sorted { lhs, rhs in
            lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }
    }

    func modelChoices(for providerID: String) -> [OpenCodeModelChoice] {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProviderID.isEmpty else { return [] }

        let configuredProvider = configuredProviders.first { provider in
            provider.id.caseInsensitiveCompare(normalizedProviderID) == .orderedSame
        }
        if let configuredProvider, !configuredProvider.models.isEmpty {
            return modelChoices(from: configuredProvider)
        }

        guard let provider = providers.first(where: { provider in
            provider.id.caseInsensitiveCompare(normalizedProviderID) == .orderedSame
        }) else {
            return []
        }

        return modelChoices(from: provider)
    }

    func hasModel(providerID: String, modelID: String) -> Bool {
        modelChoices(for: providerID).contains { choice in
            choice.modelID.caseInsensitiveCompare(modelID) == .orderedSame
        }
    }

    private func modelChoices(from provider: OpenCodeProvider) -> [OpenCodeModelChoice] {
        provider.models.values.map { model in
            OpenCodeModelChoice(
                providerID: provider.id,
                providerName: provider.name,
                modelID: model.id,
                modelName: model.name
            )
        }
        .sorted { lhs, rhs in
            lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
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
            let availableChoices = status?.modelChoices(for: normalizedProviderID) ?? []
            if !availableChoices.isEmpty,
               status?.hasModel(providerID: normalizedProviderID, modelID: defaultModel) == false {
                return nil
            }
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

enum OpenCodeAIProviderCredentialScope: Equatable {
    case global
    case server(UUID)
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
        let resolvedConfiguredProviders = try? await client.configuredProviders(sshSession: session, directory: project.path)

        return OpenCodeProviderStatus(
            providers: resolvedProviders.all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            configuredProviders: resolvedConfiguredProviders?.providers.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            } ?? [],
            defaultModels: resolvedConfiguredProviders?.defaultModels.isEmpty == false
                ? resolvedConfiguredProviders?.defaultModels ?? resolvedProviders.defaultModels
                : resolvedProviders.defaultModels,
            connectedProviderIDs: resolvedProviders.connected.sorted(),
            authMethods: resolvedAuthMethods
        )
    }

    func status(for server: Server) async throws -> OpenCodeProviderStatus {
        let session = try await sshService.connect(to: server, purpose: .opencode)
        defer { session.disconnect() }

        let client = client(for: server.id)
        let resolvedProviders = try await client.providerList(sshSession: session)
        let resolvedAuthMethods = try await client.providerAuthMethods(sshSession: session)
        let resolvedConfiguredProviders = try? await client.configuredProviders(sshSession: session)

        return OpenCodeProviderStatus(
            providers: resolvedProviders.all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            configuredProviders: resolvedConfiguredProviders?.providers.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            } ?? [],
            defaultModels: resolvedConfiguredProviders?.defaultModels.isEmpty == false
                ? resolvedConfiguredProviders?.defaultModels ?? resolvedProviders.defaultModels
                : resolvedProviders.defaultModels,
            connectedProviderIDs: resolvedProviders.connected.sorted(),
            authMethods: resolvedAuthMethods
        )
    }

    func startOAuth(
        providerID: String,
        methodIndex: Int,
        inputs: [String: String] = [:],
        on server: Server
    ) async throws -> OpenCodeProviderOAuthAuthorization {
        let trimmedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProviderID.isEmpty else {
            throw OpenCodeProviderServiceError.invalidInput
        }

        let session = try await sshService.connect(to: server, purpose: .opencode)
        defer { session.disconnect() }

        return try await client(for: server.id).startProviderOAuth(
            sshSession: session,
            providerID: trimmedProviderID,
            methodIndex: methodIndex,
            inputs: inputs
        )
    }

    func completeOAuth(
        providerID: String,
        methodIndex: Int,
        code: String? = nil,
        on server: Server
    ) async throws {
        let trimmedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProviderID.isEmpty else {
            throw OpenCodeProviderServiceError.invalidInput
        }

        let session = try await sshService.connect(to: server, purpose: .opencode)
        defer { session.disconnect() }

        let client = client(for: server.id)
        _ = try await client.completeProviderOAuth(
            sshSession: session,
            providerID: trimmedProviderID,
            methodIndex: methodIndex,
            code: code
        )
        let _ = try? await client.disposeInstance(sshSession: session)
    }

    func saveAPIKey(_ apiKey: String, providerID: String, for project: RemoteProject) async throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedProviderID.isEmpty else {
            throw OpenCodeProviderServiceError.invalidInput
        }

        try KeychainManager.shared.storeOpenCodeAPIKey(trimmedKey, providerID: trimmedProviderID)

        let session = try await sshService.getConnection(for: project, purpose: .opencode)
        let client = client(for: project)
        _ = try await client.setProviderAPIKey(
            sshSession: session,
            providerID: trimmedProviderID,
            apiKey: trimmedKey,
            directory: project.path
        )
    }

    func applyAIProviderProfile(
        _ profile: OpenCodeAIProviderProfile,
        credentialScope: OpenCodeAIProviderCredentialScope,
        to server: Server
    ) async throws {
        let normalizedProfile = profile.normalizedForStorage()
        guard normalizedProfile.isReadyToSave else {
            throw OpenCodeProviderServiceError.invalidInput
        }

        let session = try await sshService.connect(to: server, purpose: .opencode)
        defer { session.disconnect() }

        let openCodeClient = client(for: server.id)
        var loaded = try await loadGlobalConfiguration(session: session)
        if normalizedProfile.isCustomProvider {
            try loaded.document.setCustomOpenAICompatibleProvider(
                id: normalizedProfile.providerID,
                name: normalizedProfile.providerName,
                baseURL: normalizedProfile.customBaseURL,
                modelID: normalizedProfile.customModelID,
                modelName: normalizedProfile.customModelName,
                npmPackage: normalizedProfile.npmPackage
            )
        } else if let provider = try await catalogProvider(
            matching: normalizedProfile.providerID,
            client: openCodeClient,
            session: session
        ), provider.requiresExplicitConfiguration {
            try loaded.document.setCatalogProvider(
                provider,
                preferredModelID: OpenCodePromptModel(fullID: normalizedProfile.resolvedModelID ?? "")?.modelID
            )
        }

        loaded.document.setModelSelection(
            modelID: normalizedProfile.resolvedModelID,
            smallModelID: normalizedProfile.resolvedSmallModelID
        )
        try await writeConfiguration(loaded.document, to: loaded.path, session: session)
        try await reloadConfiguration(loaded.document, client: openCodeClient, session: session, directory: nil)

        if normalizedProfile.requiresAPIKeyCredential {
            let apiKey = try retrieveAPIKey(for: normalizedProfile.providerID, scope: credentialScope)
            _ = try await openCodeClient.setProviderAPIKey(
                sshSession: session,
                providerID: normalizedProfile.providerID,
                apiKey: apiKey
            )
        }

        try await validateProfile(
            normalizedProfile,
            client: openCodeClient,
            session: session,
            directory: nil
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

        let openCodeSession = try await sshService.getConnection(for: project, purpose: .opencode)
        try await reloadConfiguration(
            loaded.document,
            client: client(for: project),
            session: openCodeSession,
            directory: scope == .project ? project.path : nil
        )
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
            modelName: input.modelName
        )
        loaded.document.setModelSelection(modelID: "\(providerID)/\(input.modelID)", smallModelID: loaded.document.selectedSmallModelID)
        try await writeConfiguration(loaded.document, to: loaded.path, session: session)

        try KeychainManager.shared.storeOpenCodeAPIKey(apiKey, providerID: providerID)

        let client = client(for: project)
        let openCodeSession = try await sshService.getConnection(for: project, purpose: .opencode)
        try await reloadConfiguration(
            loaded.document,
            client: client,
            session: openCodeSession,
            directory: scope == .project ? project.path : nil
        )
        _ = try await client.setProviderAPIKey(
            sshSession: openCodeSession,
            providerID: providerID,
            apiKey: apiKey,
            directory: project.path
        )
        try await validateModel(
            OpenCodePromptModel(providerID: providerID, modelID: input.modelID),
            client: client,
            session: openCodeSession,
            directory: project.path
        )
    }
}

enum OpenCodeProviderServiceError: LocalizedError {
    case invalidInput
    case missingAPIKey(String)
    case modelNotConfigured(String)
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Provider ID and model configuration are required."
        case .missingAPIKey(let providerID):
            return "No local API key is stored for \(providerID)."
        case .modelNotConfigured(let modelID):
            return "OpenCode did not load \(modelID). Sync the provider config and try again."
        case .validationFailed(let message):
            return "OpenCode provider validation failed: \(message)"
        }
    }
}

private extension OpenCodeProviderService {
    func client(for project: RemoteProject) -> OpenCodeClient {
        clientOverride ?? OpenCodeClientFactory.client(for: project.serverId)
    }

    func client(for serverID: UUID) -> OpenCodeClient {
        clientOverride ?? OpenCodeClientFactory.client(for: serverID)
    }

    func catalogProvider(
        matching providerID: String,
        client: OpenCodeClient,
        session: SSHSession
    ) async throws -> OpenCodeProvider? {
        let normalizedID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return nil }
        let response = try await client.providerList(sshSession: session)
        return response.all.first { provider in
            provider.id.caseInsensitiveCompare(normalizedID) == .orderedSame
        }
    }

    func reloadConfiguration(
        _ document: OpenCodeMCPConfigDocument,
        client: OpenCodeClient,
        session: SSHSession,
        directory: String?
    ) async throws {
        try await client.patchConfiguration(
            sshSession: session,
            json: document.toJSONString(),
            directory: directory
        )
    }

    func validateProfile(
        _ profile: OpenCodeAIProviderProfile,
        client: OpenCodeClient,
        session: SSHSession,
        directory: String?
    ) async throws {
        guard let modelID = profile.resolvedModelID,
              let model = OpenCodePromptModel(fullID: modelID) else {
            return
        }
        try await validateModel(model, client: client, session: session, directory: directory)
    }

    func validateModel(
        _ model: OpenCodePromptModel,
        client: OpenCodeClient,
        session: SSHSession,
        directory: String?
    ) async throws {
        let configured = try await client.configuredProviders(sshSession: session, directory: directory)
        guard configured.providers.contains(where: { provider in
            provider.id.caseInsensitiveCompare(model.providerID) == .orderedSame
                && provider.models.values.contains { $0.id.caseInsensitiveCompare(model.modelID) == .orderedSame }
        }) else {
            throw OpenCodeProviderServiceError.modelNotConfigured(model.fullID)
        }

        let created = try await client.createSession(
            sshSession: session,
            title: "CodeAgents provider validation",
            directory: directory
        )
        guard let sessionID = created.id?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            throw OpenCodeClientError.invalidResponse("OpenCode did not return a validation session id.")
        }

        let eventPath = OpenCodeSessionPath.path("/event", directory: directory)
        let eventIterator = OpenCodeProviderValidationEventIterator(
            stream: client.streamEvents(session: session, path: eventPath)
        )
        _ = try await nextValidationEvent(
            from: eventIterator,
            timeoutNanoseconds: 5_000_000_000
        )

        try await client.promptAsync(
            sshSession: session,
            sessionID: sessionID,
            payload: OpenCodePromptPayload(
                model: model,
                system: "Validate the provider connection. Reply with exactly OK.",
                tools: [:],
                parts: [.text("Reply with exactly OK.")]
            ),
            directory: directory
        )

        try await waitForValidationReply(
            sessionID: sessionID,
            model: model,
            eventIterator: eventIterator
        )
    }

    func waitForValidationReply(
        sessionID: String,
        model: OpenCodePromptModel,
        eventIterator: OpenCodeProviderValidationEventIterator
    ) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let remaining = UInt64(max(1, deadline.timeIntervalSinceNow) * 1_000_000_000)
            guard let event = try await nextValidationEvent(
                from: eventIterator,
                timeoutNanoseconds: min(remaining, 5_000_000_000)
            ) else {
                continue
            }

            switch event {
            case .sessionError(let properties, _):
                guard validationEventMatches(properties.sessionID, sessionID: sessionID) else { continue }
                throw OpenCodeProviderServiceError.validationFailed(properties.error.displayMessage)

            case .messageUpdated(let properties, _):
                guard validationEventMatches(properties.sessionID ?? properties.info.sessionID, sessionID: sessionID) else {
                    continue
                }
                if let error = properties.info.error {
                    throw OpenCodeProviderServiceError.validationFailed(error.displayMessage)
                }
                if properties.info.role != "user" {
                    return
                }

            case .messagePartUpdated(let properties, _):
                guard validationEventMatches(properties.sessionID ?? properties.part.payload.sessionID, sessionID: sessionID) else {
                    continue
                }
                if let error = properties.part.payload.error {
                    throw OpenCodeProviderServiceError.validationFailed(error.displayMessage)
                }
                if properties.part.payload.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    return
                }

            case .messagePartDelta(let properties, _):
                guard validationEventMatches(properties.sessionID ?? properties.part?.payload.sessionID, sessionID: sessionID) else {
                    continue
                }
                if properties.delta?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    || properties.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    return
                }

            case .sessionIdle(let properties, _):
                guard validationEventMatches(properties.sessionID ?? properties.id, sessionID: sessionID) else { continue }
                return

            case .sessionStatus(let properties, _):
                guard validationEventMatches(properties.sessionID, sessionID: sessionID),
                      properties.status.type == "idle" else { continue }
                return

            default:
                continue
            }
        }

        throw OpenCodeProviderServiceError.validationFailed(
            "\(model.fullID) accepted the prompt but did not return a validation reply."
        )
    }

    func nextValidationEvent(
        from iterator: OpenCodeProviderValidationEventIterator,
        timeoutNanoseconds: UInt64
    ) async throws -> OpenCodeEvent? {
        try await withThrowingTaskGroup(of: OpenCodeEvent?.self) { group in
            group.addTask {
                try await iterator.next()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }

            guard let result = try await group.next() else {
                return nil
            }
            group.cancelAll()
            return result
        }
    }

    func validationEventMatches(_ candidate: String?, sessionID: String) -> Bool {
        candidate?.trimmingCharacters(in: .whitespacesAndNewlines) == sessionID
    }

    func loadConfiguration(
        for project: RemoteProject,
        scope: OpenCodeConfigurationScope,
        session: SSHSession
    ) async throws -> (path: String, document: OpenCodeMCPConfigDocument) {
        if scope == .global {
            return try await loadGlobalConfiguration(session: session)
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

    func loadGlobalConfiguration(session: SSHSession) async throws -> (path: String, document: OpenCodeMCPConfigDocument) {
        let path = try await globalConfigurationPath(session: session)
        return (path, try await readConfiguration(at: path, session: session))
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

    func retrieveAPIKey(for providerID: String, scope: OpenCodeAIProviderCredentialScope) throws -> String {
        switch scope {
        case .global:
            return try KeychainManager.shared.retrieveOpenCodeAPIKey(providerID: providerID)
        case .server(let serverID):
            return try KeychainManager.shared.retrieveOpenCodeAPIKey(providerID: providerID, serverID: serverID)
        }
    }
}

private actor OpenCodeProviderValidationEventIterator {
    private var iterator: AsyncThrowingStream<OpenCodeEvent, Error>.Iterator

    init(stream: AsyncThrowingStream<OpenCodeEvent, Error>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> OpenCodeEvent? {
        var activeIterator = iterator
        let event = try await activeIterator.next()
        iterator = activeIterator
        return event
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
