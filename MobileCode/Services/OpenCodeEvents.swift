//
//  OpenCodeEvents.swift
//  CodeAgentsMobile
//
//  Purpose: Parse OpenCode SSE frames and map event payloads into typed DTOs
//

import Foundation

struct OpenCodeServerSentEvent {
    let id: String?
    let event: String?
    let retry: Int?
    let data: String
}

final class OpenCodeSSEParser {
    private var dataLines: [String] = []
    private var eventId: String?
    private var eventName: String?
    private var retry: Int?

    func consume(line rawLine: String) -> [OpenCodeServerSentEvent] {
        let line = rawLine.removingTrailingNewline()
        guard !line.isEmpty else {
            return flush()
        }

        guard !line.hasPrefix(":") else {
            return []
        }

        let field: String
        let value: String
        if let separator = line.firstIndex(of: ":") {
            field = String(line[..<separator])
            let rawValue = line[line.index(after: separator)...]
            value = rawValue.hasPrefix(" ") ? String(rawValue.dropFirst()) : String(rawValue)
        } else {
            field = line
            value = ""
        }

        switch field {
        case "data":
            dataLines.append(value)
        case "event":
            eventName = value
        case "id":
            eventId = value.contains("\0") ? eventId : value
        case "retry":
            retry = Int(value)
        default:
            break
        }

        return []
    }

    func flush() -> [OpenCodeServerSentEvent] {
        guard !dataLines.isEmpty else { return [] }
        let event = OpenCodeServerSentEvent(
            id: eventId,
            event: eventName,
            retry: retry,
            data: dataLines.joined(separator: "\n")
        )
        dataLines = []
        eventName = nil
        retry = nil
        return [event]
    }
}

final class OpenCodeSSEStreamParser {
    private let parser = OpenCodeSSEParser()
    private var buffer = ""

    func consume(_ chunk: String) -> [OpenCodeServerSentEvent] {
        buffer += chunk
        var events: [OpenCodeServerSentEvent] = []

        while let newlineIndex = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newlineIndex])
            buffer = String(buffer[buffer.index(after: newlineIndex)...])
            events.append(contentsOf: parser.consume(line: line))
        }

        return events
    }

    func finish() -> [OpenCodeServerSentEvent] {
        var events: [OpenCodeServerSentEvent] = []
        if !buffer.isEmpty {
            events.append(contentsOf: parser.consume(line: buffer))
            buffer = ""
        }
        events.append(contentsOf: parser.flush())
        return events
    }
}

enum OpenCodeEvent {
    case serverConnected(OpenCodeRawEvent)
    case serverHeartbeat(OpenCodeRawEvent)
    case messageUpdated(OpenCodeMessageUpdatedProperties, raw: OpenCodeRawEvent)
    case messagePartUpdated(OpenCodeMessagePartUpdatedProperties, raw: OpenCodeRawEvent)
    case messagePartDelta(OpenCodeMessagePartDeltaProperties, raw: OpenCodeRawEvent)
    case messagePartRemoved(OpenCodeMessagePartRemovedProperties, raw: OpenCodeRawEvent)
    case messageRemoved(OpenCodeMessageRemovedProperties, raw: OpenCodeRawEvent)
    case sessionStatus(OpenCodeSessionStatusProperties, raw: OpenCodeRawEvent)
    case sessionIdle(OpenCodeSessionIDProperties, raw: OpenCodeRawEvent)
    case sessionError(OpenCodeSessionErrorProperties, raw: OpenCodeRawEvent)
    case sessionDiff(OpenCodeSessionDiffProperties, raw: OpenCodeRawEvent)
    case sessionCompacted(OpenCodeSessionIDProperties, raw: OpenCodeRawEvent)
    case sessionCreated(OpenCodeSessionInfoProperties, raw: OpenCodeRawEvent)
    case sessionUpdated(OpenCodeSessionInfoProperties, raw: OpenCodeRawEvent)
    case sessionDeleted(OpenCodeSessionIDProperties, raw: OpenCodeRawEvent)
    case permissionUpdated(OpenCodePermissionProperties, raw: OpenCodeRawEvent)
    case permissionReplied(OpenCodePermissionProperties, raw: OpenCodeRawEvent)
    case fileEdited(OpenCodeRawEvent)
    case todoUpdated(OpenCodeRawEvent)
    case commandExecuted(OpenCodeRawEvent)
    case unknown(OpenCodeRawEvent)

    var rawEvent: OpenCodeRawEvent {
        switch self {
        case .serverConnected(let raw),
             .serverHeartbeat(let raw),
             .fileEdited(let raw),
             .todoUpdated(let raw),
             .commandExecuted(let raw),
             .unknown(let raw):
            return raw
        case .messageUpdated(_, let raw),
             .messagePartUpdated(_, let raw),
             .messagePartDelta(_, let raw),
             .messagePartRemoved(_, let raw),
             .messageRemoved(_, let raw),
             .sessionStatus(_, let raw),
             .sessionIdle(_, let raw),
             .sessionError(_, let raw),
             .sessionDiff(_, let raw),
             .sessionCompacted(_, let raw),
             .sessionCreated(_, let raw),
             .sessionUpdated(_, let raw),
             .sessionDeleted(_, let raw),
             .permissionUpdated(_, let raw),
             .permissionReplied(_, let raw):
            return raw
        }
    }
}

struct OpenCodeRawEvent: Decodable {
    let type: String
    let properties: [String: AnyCodable]
    let context: OpenCodeGlobalEventContext?

    enum CodingKeys: String, CodingKey {
        case type
        case properties
    }

    init(type: String, properties: [String: AnyCodable], context: OpenCodeGlobalEventContext? = nil) {
        self.type = type
        self.properties = properties
        self.context = context
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        properties = try container.decodeIfPresent([String: AnyCodable].self, forKey: .properties) ?? [:]
        context = nil
    }
}

struct OpenCodeGlobalEventContext: Decodable {
    let directory: String?
    let project: String?
    let workspace: String?
}

private struct OpenCodeGlobalEventEnvelope: Decodable {
    let directory: String?
    let project: String?
    let workspace: String?
    let payload: OpenCodeRawEvent

    var rawEvent: OpenCodeRawEvent {
        OpenCodeRawEvent(
            type: payload.type,
            properties: payload.properties,
            context: OpenCodeGlobalEventContext(directory: directory, project: project, workspace: workspace)
        )
    }
}

enum OpenCodeEventMapper {
    private static let decoder = JSONDecoder()

    static func decode(_ serverSentEvent: OpenCodeServerSentEvent) throws -> OpenCodeEvent {
        try decodeJSON(serverSentEvent.data)
    }

    static func decodeJSON(_ jsonLine: String) throws -> OpenCodeEvent {
        guard let data = jsonLine.data(using: .utf8) else {
            throw OpenCodeEventMapperError.invalidUTF8
        }

        let rawEvent: OpenCodeRawEvent
        if let event = try? decoder.decode(OpenCodeRawEvent.self, from: data) {
            rawEvent = event
        } else {
            rawEvent = try decoder.decode(OpenCodeGlobalEventEnvelope.self, from: data).rawEvent
        }

        return try map(rawEvent)
    }

    static func map(_ rawEvent: OpenCodeRawEvent) throws -> OpenCodeEvent {
        switch rawEvent.type {
        case "server.connected":
            return .serverConnected(rawEvent)
        case "server.heartbeat":
            return .serverHeartbeat(rawEvent)
        case "message.updated":
            return .messageUpdated(try decodeProperties(rawEvent, as: OpenCodeMessageUpdatedProperties.self), raw: rawEvent)
        case "message.part.updated":
            return .messagePartUpdated(try decodeProperties(rawEvent, as: OpenCodeMessagePartUpdatedProperties.self), raw: rawEvent)
        case "message.part.delta":
            return .messagePartDelta(try decodeProperties(rawEvent, as: OpenCodeMessagePartDeltaProperties.self), raw: rawEvent)
        case "message.part.removed":
            return .messagePartRemoved(try decodeProperties(rawEvent, as: OpenCodeMessagePartRemovedProperties.self), raw: rawEvent)
        case "message.removed":
            return .messageRemoved(try decodeProperties(rawEvent, as: OpenCodeMessageRemovedProperties.self), raw: rawEvent)
        case "session.status":
            return .sessionStatus(try decodeProperties(rawEvent, as: OpenCodeSessionStatusProperties.self), raw: rawEvent)
        case "session.idle":
            return .sessionIdle(try decodeProperties(rawEvent, as: OpenCodeSessionIDProperties.self), raw: rawEvent)
        case "session.error":
            return .sessionError(try decodeProperties(rawEvent, as: OpenCodeSessionErrorProperties.self), raw: rawEvent)
        case "session.diff":
            return .sessionDiff(try decodeProperties(rawEvent, as: OpenCodeSessionDiffProperties.self), raw: rawEvent)
        case "session.compacted":
            return .sessionCompacted(try decodeProperties(rawEvent, as: OpenCodeSessionIDProperties.self), raw: rawEvent)
        case "session.created":
            return .sessionCreated(try decodeProperties(rawEvent, as: OpenCodeSessionInfoProperties.self), raw: rawEvent)
        case "session.updated":
            return .sessionUpdated(try decodeProperties(rawEvent, as: OpenCodeSessionInfoProperties.self), raw: rawEvent)
        case "session.deleted":
            return .sessionDeleted(try decodeProperties(rawEvent, as: OpenCodeSessionIDProperties.self), raw: rawEvent)
        case "permission.updated":
            return .permissionUpdated(try decodeProperties(rawEvent, as: OpenCodePermissionProperties.self), raw: rawEvent)
        case "permission.replied":
            return .permissionReplied(try decodeProperties(rawEvent, as: OpenCodePermissionProperties.self), raw: rawEvent)
        case "file.edited":
            return .fileEdited(rawEvent)
        case "todo.updated":
            return .todoUpdated(rawEvent)
        case "command.executed":
            return .commandExecuted(rawEvent)
        default:
            return .unknown(rawEvent)
        }
    }

    private static func decodeProperties<T: Decodable>(_ rawEvent: OpenCodeRawEvent, as type: T.Type) throws -> T {
        let object = rawEvent.properties.mapValues { $0.value }
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        return try decoder.decode(T.self, from: data)
    }
}

enum OpenCodeEventMapperError: LocalizedError {
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "OpenCode event data is not UTF-8"
        }
    }
}

struct OpenCodeMessageUpdatedProperties: Decodable {
    let sessionID: String?
    let info: OpenCodeMessageInfo
}

struct OpenCodeMessageInfo: Decodable {
    let id: String
    let parentID: String?
    let role: String?
    let mode: String?
    let agent: String?
    let sessionID: String?
    let model: OpenCodeModelInfo?
    let modelID: String?
    let providerID: String?
    let path: OpenCodePathInfo?
    let cost: Double?
    let tokens: OpenCodeTokenUsage?
    let time: OpenCodeTimeInfo?
    let error: OpenCodeErrorInfo?
}

struct OpenCodeModelInfo: Decodable {
    let providerID: String?
    let modelID: String?
}

struct OpenCodePathInfo: Decodable {
    let cwd: String?
    let root: String?
}

struct OpenCodeTokenUsage: Decodable {
    let input: Int?
    let output: Int?
    let reasoning: Int?
    let cache: OpenCodeCacheUsage?
}

struct OpenCodeCacheUsage: Decodable {
    let read: Int?
    let write: Int?
}

struct OpenCodeTimeInfo: Decodable {
    let created: Int?
    let updated: Int?
    let completed: Int?
}

struct OpenCodeMessagePartUpdatedProperties: Decodable {
    let sessionID: String?
    let part: OpenCodeMessagePart
    let time: Int?
    let delta: String?
}

struct OpenCodeMessagePartDeltaProperties: Decodable {
    let sessionID: String?
    let messageID: String?
    let partID: String?
    let id: String?
    let type: String?
    let delta: String?
    let text: String?
    let part: OpenCodeMessagePart?
    let time: Int?
}

struct OpenCodeMessagePartRemovedProperties: Decodable {
    let sessionID: String?
    let messageID: String?
    let partID: String?
    let id: String?
}

struct OpenCodeMessageRemovedProperties: Decodable {
    let sessionID: String?
    let messageID: String?
    let id: String?
}

enum OpenCodeMessagePart: Decodable {
    case text(OpenCodeMessagePartPayload)
    case reasoning(OpenCodeMessagePartPayload)
    case file(OpenCodeMessagePartPayload)
    case tool(OpenCodeMessagePartPayload)
    case stepStart(OpenCodeMessagePartPayload)
    case stepFinish(OpenCodeMessagePartPayload)
    case snapshot(OpenCodeMessagePartPayload)
    case patch(OpenCodeMessagePartPayload)
    case agent(OpenCodeMessagePartPayload)
    case subtask(OpenCodeMessagePartPayload)
    case retry(OpenCodeMessagePartPayload)
    case compaction(OpenCodeMessagePartPayload)
    case unknown(OpenCodeMessagePartPayload)

    var payload: OpenCodeMessagePartPayload {
        switch self {
        case .text(let payload),
             .reasoning(let payload),
             .file(let payload),
             .tool(let payload),
             .stepStart(let payload),
             .stepFinish(let payload),
             .snapshot(let payload),
             .patch(let payload),
             .agent(let payload),
             .subtask(let payload),
             .retry(let payload),
             .compaction(let payload),
             .unknown(let payload):
            return payload
        }
    }

    init(from decoder: Decoder) throws {
        let payload = try OpenCodeMessagePartPayload(from: decoder)
        switch payload.type {
        case "text":
            self = .text(payload)
        case "reasoning":
            self = .reasoning(payload)
        case "file":
            self = .file(payload)
        case "tool":
            self = .tool(payload)
        case "step-start":
            self = .stepStart(payload)
        case "step-finish":
            self = .stepFinish(payload)
        case "snapshot":
            self = .snapshot(payload)
        case "patch":
            self = .patch(payload)
        case "agent":
            self = .agent(payload)
        case "subtask":
            self = .subtask(payload)
        case "retry":
            self = .retry(payload)
        case "compaction":
            self = .compaction(payload)
        default:
            self = .unknown(payload)
        }
    }
}

struct OpenCodeMessagePartPayload: Decodable {
    let type: String
    let id: String?
    let messageID: String?
    let sessionID: String?
    let text: String?
    let title: String?
    let path: String?
    let url: String?
    let mime: String?
    let source: String?
    let callID: String?
    let tool: String?
    let state: OpenCodeToolState?
    let input: [String: AnyCodable]?
    let output: AnyCodable?
    let error: OpenCodeErrorInfo?
    let raw: [String: AnyCodable]

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case messageID
        case sessionID
        case text
        case title
        case path
        case url
        case mime
        case source
        case callID
        case tool
        case state
        case input
        case output
        case error
    }

    init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode([String: AnyCodable].self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        mime = try container.decodeIfPresent(String.self, forKey: .mime)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        callID = try container.decodeIfPresent(String.self, forKey: .callID)
        tool = try container.decodeIfPresent(String.self, forKey: .tool)
        state = try container.decodeIfPresent(OpenCodeToolState.self, forKey: .state)
        input = try container.decodeIfPresent([String: AnyCodable].self, forKey: .input)
        output = try container.decodeIfPresent(AnyCodable.self, forKey: .output)
        error = try container.decodeIfPresent(OpenCodeErrorInfo.self, forKey: .error)
    }
}

struct OpenCodeToolState: Decodable {
    let status: String
    let title: String?
    let input: [String: AnyCodable]?
    let output: AnyCodable?
    let error: OpenCodeErrorInfo?
    let raw: [String: AnyCodable]

    enum CodingKeys: String, CodingKey {
        case status
        case title
        case input
        case output
        case error
    }

    init(from decoder: Decoder) throws {
        if let status = try? decoder.singleValueContainer().decode(String.self) {
            self.status = status
            title = nil
            input = nil
            output = nil
            error = nil
            raw = ["status": AnyCodable(status)]
            return
        }

        raw = try decoder.singleValueContainer().decode([String: AnyCodable].self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        title = try container.decodeIfPresent(String.self, forKey: .title)
        input = try container.decodeIfPresent([String: AnyCodable].self, forKey: .input)
        output = try container.decodeIfPresent(AnyCodable.self, forKey: .output)
        error = try container.decodeIfPresent(OpenCodeErrorInfo.self, forKey: .error)
    }
}

struct OpenCodeSessionIDProperties: Decodable {
    let sessionID: String?
    let id: String?
    let info: OpenCodeSessionInfo?
}

struct OpenCodeSessionStatusProperties: Decodable {
    let sessionID: String?
    let status: OpenCodeSessionStatus
}

struct OpenCodeSessionStatus: Decodable {
    let type: String
    let raw: [String: AnyCodable]

    enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode([String: AnyCodable].self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
    }
}

struct OpenCodeSessionErrorProperties: Decodable {
    let sessionID: String?
    let error: OpenCodeErrorInfo
}

struct OpenCodeSessionDiffProperties: Decodable {
    let sessionID: String?
    let diff: [AnyCodable]
}

struct OpenCodeSessionInfoProperties: Decodable {
    let sessionID: String?
    let info: OpenCodeSessionInfo?
}

struct OpenCodeSessionInfo: Decodable {
    let id: String?
    let slug: String?
    let projectID: String?
    let directory: String?
    let title: String?
    let version: String?
    let time: OpenCodeTimeInfo?
}

struct OpenCodePermissionProperties: Decodable {
    let id: String?
    let type: String?
    let pattern: OpenCodePermissionPattern?
    let sessionID: String?
    let messageID: String?
    let callID: String?
    let permissionID: String?
    let title: String?
    let metadata: [String: AnyCodable]?
    let response: String?
    let time: OpenCodeTimeInfo?
}

enum OpenCodePermissionPattern: Decodable {
    case string(String)
    case strings([String])

    var values: [String] {
        switch self {
        case .string(let value):
            return [value]
        case .strings(let values):
            return values
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .strings(try container.decode([String].self))
        }
    }
}

struct OpenCodeErrorInfo: Decodable {
    let name: String?
    let message: String?
    let data: [String: AnyCodable]?
    let raw: [String: AnyCodable]

    enum CodingKeys: String, CodingKey {
        case name
        case message
        case data
    }

    init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode([String: AnyCodable].self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        data = try container.decodeIfPresent([String: AnyCodable].self, forKey: .data)
    }
}

private extension String {
    func removingTrailingNewline() -> String {
        var line = self
        if line.hasSuffix("\n") {
            line.removeLast()
        }
        if line.hasSuffix("\r") {
            line.removeLast()
        }
        return line
    }
}
