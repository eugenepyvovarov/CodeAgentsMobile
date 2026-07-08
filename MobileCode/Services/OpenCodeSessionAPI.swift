//
//  OpenCodeSessionAPI.swift
//  CodeAgentsMobile
//
//  Purpose: Typed OpenCode session endpoints and prompt payloads
//

import Foundation

extension OpenCodeClient {
    func listSessions(sshSession: SSHSession, directory: String? = nil) async throws -> [OpenCodeSessionInfo] {
        try await jsonRequest(
            session: sshSession,
            method: .get,
            path: OpenCodeSessionPath.path("/session", directory: directory),
            responseType: [OpenCodeSessionInfo].self
        )
    }

    func createSession(
        sshSession: SSHSession,
        parentID: String? = nil,
        title: String? = nil,
        directory: String? = nil
    ) async throws -> OpenCodeSessionInfo {
        let payload = OpenCodeCreateSessionPayload(parentID: parentID, title: title)
        return try await jsonRequest(
            session: sshSession,
            method: .post,
            path: OpenCodeSessionPath.path("/session", directory: directory),
            body: OpenCodeSessionJSON.encode(payload),
            responseType: OpenCodeSessionInfo.self
        )
    }

    func sessionStatus(
        sshSession: SSHSession,
        directory: String? = nil
    ) async throws -> [String: OpenCodeSessionStatus] {
        try await jsonRequest(
            session: sshSession,
            method: .get,
            path: OpenCodeSessionPath.path("/session/status", directory: directory),
            responseType: [String: OpenCodeSessionStatus].self
        )
    }

    func sessionMessages(
        sshSession: SSHSession,
        sessionID: String,
        directory: String? = nil,
        limit: Int? = nil
    ) async throws -> [OpenCodeSessionMessage] {
        var query: [String: String] = [:]
        if let directory {
            query["directory"] = directory
        }
        if let limit {
            query["limit"] = String(limit)
        }

        return try await jsonRequest(
            session: sshSession,
            method: .get,
            path: OpenCodeSessionPath.path(
                "/session/\(OpenCodeSessionPath.escape(sessionID))/message",
                query: query
            ),
            responseType: [OpenCodeSessionMessage].self
        )
    }

    func sessionMessage(
        sshSession: SSHSession,
        sessionID: String,
        messageID: String,
        directory: String? = nil
    ) async throws -> OpenCodeSessionMessage {
        try await jsonRequest(
            session: sshSession,
            method: .get,
            path: OpenCodeSessionPath.path(
                "/session/\(OpenCodeSessionPath.escape(sessionID))/message/\(OpenCodeSessionPath.escape(messageID))",
                directory: directory
            ),
            responseType: OpenCodeSessionMessage.self
        )
    }

    func sendMessage(
        sshSession: SSHSession,
        sessionID: String,
        payload: OpenCodePromptPayload,
        directory: String? = nil
    ) async throws -> OpenCodeSessionMessage {
        try await jsonRequest(
            session: sshSession,
            method: .post,
            path: OpenCodeSessionPath.path(
                "/session/\(OpenCodeSessionPath.escape(sessionID))/message",
                directory: directory
            ),
            body: OpenCodeSessionJSON.encode(payload),
            responseType: OpenCodeSessionMessage.self
        )
    }

    @discardableResult
    func promptAsync(
        sshSession: SSHSession,
        sessionID: String,
        payload: OpenCodePromptPayload,
        directory: String? = nil
    ) async throws -> OpenCodeHTTPResponse {
        try await request(
            session: sshSession,
            method: .post,
            path: OpenCodeSessionPath.path(
                "/session/\(OpenCodeSessionPath.escape(sessionID))/prompt_async",
                directory: directory
            ),
            body: OpenCodeSessionJSON.encode(payload)
        )
    }

    func abortSession(
        sshSession: SSHSession,
        sessionID: String,
        directory: String? = nil
    ) async throws -> Bool {
        try await jsonRequest(
            session: sshSession,
            method: .post,
            path: OpenCodeSessionPath.path(
                "/session/\(OpenCodeSessionPath.escape(sessionID))/abort",
                directory: directory
            ),
            responseType: Bool.self
        )
    }

    @discardableResult
    func disposeInstance(sshSession: SSHSession) async throws -> Bool {
        try await jsonRequest(
            session: sshSession,
            method: .post,
            path: "/instance/dispose",
            responseType: Bool.self
        )
    }

    @discardableResult
    func replyPermission(
        sshSession: SSHSession,
        sessionID: String,
        permissionID: String,
        response: String,
        directory: String? = nil
    ) async throws -> OpenCodeHTTPResponse {
        try await request(
            session: sshSession,
            method: .post,
            path: OpenCodeSessionPath.path(
                "/session/\(OpenCodeSessionPath.escape(sessionID))/permissions/\(OpenCodeSessionPath.escape(permissionID))",
                directory: directory
            ),
            body: OpenCodeSessionJSON.encode(OpenCodePermissionReplyPayload(response: response))
        )
    }

    func listQuestions(sshSession: SSHSession, directory: String? = nil) async throws -> [OpenCodeQuestionRequest] {
        try await jsonRequest(
            session: sshSession,
            method: .get,
            path: OpenCodeSessionPath.path("/question", directory: directory),
            responseType: [OpenCodeQuestionRequest].self
        )
    }

    @discardableResult
    func replyQuestion(
        sshSession: SSHSession,
        requestID: String,
        answers: [[String]],
        directory: String? = nil
    ) async throws -> OpenCodeHTTPResponse {
        try await request(
            session: sshSession,
            method: .post,
            path: OpenCodeSessionPath.path(
                "/question/\(OpenCodeSessionPath.escape(requestID))/reply",
                directory: directory
            ),
            body: OpenCodeSessionJSON.encode(OpenCodeQuestionReplyPayload(answers: answers))
        )
    }

    @discardableResult
    func rejectQuestion(
        sshSession: SSHSession,
        requestID: String,
        directory: String? = nil
    ) async throws -> OpenCodeHTTPResponse {
        try await request(
            session: sshSession,
            method: .post,
            path: OpenCodeSessionPath.path(
                "/question/\(OpenCodeSessionPath.escape(requestID))/reject",
                directory: directory
            )
        )
    }
}

struct OpenCodeCreateSessionPayload: Encodable {
    let parentID: String?
    let title: String?
}

struct OpenCodePermissionReplyPayload: Encodable {
    let response: String
}

struct OpenCodeQuestionReplyPayload: Encodable {
    let answers: [[String]]
}

struct OpenCodeSessionMessage: Decodable {
    let info: OpenCodeMessageInfo
    let parts: [OpenCodeMessagePart]
}

struct OpenCodePromptPayload: Encodable {
    let messageID: String?
    let model: OpenCodePromptModel?
    /// OpenCode thinking / reasoning variant (e.g. `high`, `max`). Omitted when nil.
    let variant: String?
    let agent: String?
    let noReply: Bool?
    let system: String?
    let tools: [String: Bool]?
    let parts: [OpenCodePromptPart]

    init(
        messageID: String? = nil,
        model: OpenCodePromptModel? = nil,
        variant: String? = nil,
        agent: String? = nil,
        noReply: Bool? = nil,
        system: String? = nil,
        tools: [String: Bool]? = nil,
        parts: [OpenCodePromptPart]
    ) {
        self.messageID = messageID
        self.model = model
        self.variant = variant
        self.agent = agent
        self.noReply = noReply
        self.system = system
        self.tools = tools
        self.parts = parts
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(messageID, forKey: .messageID)
        try container.encodeIfPresent(model, forKey: .model)
        let trimmedVariant = variant?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedVariant, !trimmedVariant.isEmpty {
            try container.encode(trimmedVariant, forKey: .variant)
        }
        try container.encodeIfPresent(agent, forKey: .agent)
        try container.encodeIfPresent(noReply, forKey: .noReply)
        try container.encodeIfPresent(system, forKey: .system)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encode(parts, forKey: .parts)
    }

    private enum CodingKeys: String, CodingKey {
        case messageID, model, variant, agent, noReply, system, tools, parts
    }
}

struct OpenCodePromptModel: Encodable {
    let providerID: String
    let modelID: String

    init(providerID: String, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }

    init?(fullID: String) {
        let trimmed = fullID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(of: "/") else {
            return nil
        }

        let providerID = String(trimmed[..<separator])
        let modelID = String(trimmed[trimmed.index(after: separator)...])
        guard !providerID.isEmpty, !modelID.isEmpty else {
            return nil
        }

        self.providerID = providerID
        self.modelID = modelID
    }

    var fullID: String {
        "\(providerID)/\(modelID)"
    }
}

struct OpenCodePromptPart: Encodable {
    let id: String?
    let type: String
    let text: String?
    let synthetic: Bool?
    let ignored: Bool?
    let mime: String?
    let filename: String?
    let url: String?
    let name: String?
    let prompt: String?
    let description: String?
    let agent: String?

    static func text(_ text: String, id: String? = nil, synthetic: Bool? = nil, ignored: Bool? = nil) -> Self {
        OpenCodePromptPart(
            id: id,
            type: "text",
            text: text,
            synthetic: synthetic,
            ignored: ignored,
            mime: nil,
            filename: nil,
            url: nil,
            name: nil,
            prompt: nil,
            description: nil,
            agent: nil
        )
    }

    static func file(id: String? = nil, mime: String, filename: String? = nil, url: String) -> Self {
        OpenCodePromptPart(
            id: id,
            type: "file",
            text: nil,
            synthetic: nil,
            ignored: nil,
            mime: mime,
            filename: filename,
            url: url,
            name: nil,
            prompt: nil,
            description: nil,
            agent: nil
        )
    }

    static func agent(id: String? = nil, name: String) -> Self {
        OpenCodePromptPart(
            id: id,
            type: "agent",
            text: nil,
            synthetic: nil,
            ignored: nil,
            mime: nil,
            filename: nil,
            url: nil,
            name: name,
            prompt: nil,
            description: nil,
            agent: nil
        )
    }

    static func subtask(id: String? = nil, prompt: String, description: String, agent: String) -> Self {
        OpenCodePromptPart(
            id: id,
            type: "subtask",
            text: nil,
            synthetic: nil,
            ignored: nil,
            mime: nil,
            filename: nil,
            url: nil,
            name: nil,
            prompt: prompt,
            description: description,
            agent: agent
        )
    }
}

struct OpenCodeHydrationState: Equatable {
    let messageIDs: Set<String>
    let partIDs: Set<String>

    init(messageIDs: Set<String> = [], partIDs: Set<String> = []) {
        self.messageIDs = messageIDs
        self.partIDs = partIDs
    }

    init(messages: [OpenCodeSessionMessage]) {
        messageIDs = Set(messages.map(\.info.id))
        partIDs = Set(messages.flatMap { message in
            message.parts.compactMap(\.payload.id)
        })
    }

    func merging(_ other: OpenCodeHydrationState) -> OpenCodeHydrationState {
        OpenCodeHydrationState(
            messageIDs: messageIDs.union(other.messageIDs),
            partIDs: partIDs.union(other.partIDs)
        )
    }
}

enum OpenCodeHydrationPolicy {
    /// Initial recovery stays below the #26 measured reopen budget while still covering recent chat turns.
    static let initialMessageLimit = 100
}

enum OpenCodeHydrationMode: Equatable {
    case initialBounded(limit: Int = OpenCodeHydrationPolicy.initialMessageLimit)
    case fullRefresh

    var limit: Int? {
        switch self {
        case .initialBounded(let limit):
            return limit
        case .fullRefresh:
            return nil
        }
    }

    var replacesStoredState: Bool {
        switch self {
        case .initialBounded:
            return false
        case .fullRefresh:
            return true
        }
    }

    var timingName: String {
        switch self {
        case .initialBounded:
            return "initialBounded"
        case .fullRefresh:
            return "fullRefresh"
        }
    }
}

struct OpenCodeHydrationResult: Equatable {
    let mode: OpenCodeHydrationMode
    let fetchedCount: Int
    let selectedCount: Int
    let hydratedMessages: [CodingAgentRuntimeHydratedMessage]
    let previousState: OpenCodeHydrationState
    let observedState: OpenCodeHydrationState
    let storedState: OpenCodeHydrationState
    let diff: OpenCodeHydrationDiff
}

struct OpenCodeHydrationDiff: Equatable {
    let addedMessageIDs: Set<String>
    let removedMessageIDs: Set<String>
    let addedPartIDs: Set<String>
    let removedPartIDs: Set<String>

    var hasChanges: Bool {
        !addedMessageIDs.isEmpty
            || !removedMessageIDs.isEmpty
            || !addedPartIDs.isEmpty
            || !removedPartIDs.isEmpty
    }
}

enum OpenCodeHydrationDiffer {
    static func diff(local: OpenCodeHydrationState, remote: OpenCodeHydrationState) -> OpenCodeHydrationDiff {
        OpenCodeHydrationDiff(
            addedMessageIDs: remote.messageIDs.subtracting(local.messageIDs),
            removedMessageIDs: local.messageIDs.subtracting(remote.messageIDs),
            addedPartIDs: remote.partIDs.subtracting(local.partIDs),
            removedPartIDs: local.partIDs.subtracting(remote.partIDs)
        )
    }

    static func diff(local: OpenCodeHydrationState, remoteMessages: [OpenCodeSessionMessage]) -> OpenCodeHydrationDiff {
        diff(local: local, remote: OpenCodeHydrationState(messages: remoteMessages))
    }

    static func messagesNeedingHydration(
        local: OpenCodeHydrationState,
        remoteMessages: [OpenCodeSessionMessage]
    ) -> [OpenCodeSessionMessage] {
        remoteMessages.filter { message in
            if !local.messageIDs.contains(message.info.id) {
                return true
            }

            let partIDs = Set(message.parts.compactMap(\.payload.id))
            return !partIDs.subtracting(local.partIDs).isEmpty
        }
    }

    static func mergedState(
        local: OpenCodeHydrationState,
        observedMessages: [OpenCodeSessionMessage],
        mode: OpenCodeHydrationMode
    ) -> OpenCodeHydrationState {
        let observed = OpenCodeHydrationState(messages: observedMessages)
        if mode.replacesStoredState {
            return observed
        }
        return local.merging(observed)
    }
}

enum OpenCodeSessionJSON {
    static func encode<T: Encodable>(_ payload: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard let body = String(data: data, encoding: .utf8) else {
            throw OpenCodeClientError.invalidRequest("Payload is not UTF-8")
        }
        return body
    }
}

enum OpenCodeSessionPath {
    static func path(_ path: String, directory: String?) -> String {
        guard let directory else { return path }
        return self.path(path, query: ["directory": directory])
    }

    static func path(_ path: String, query: [String: String]) -> String {
        let items = query
            .filter { !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(escapeQuery(key))=\(escapeQuery(value))"
            }

        guard !items.isEmpty else { return path }
        return "\(path)?\(items.joined(separator: "&"))"
    }

    static func escape(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func escapeQuery(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
