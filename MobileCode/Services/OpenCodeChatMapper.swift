//
//  OpenCodeChatMapper.swift
//  CodeAgentsMobile
//
//  Purpose: Map OpenCode session messages and events into MobileCode chat chunks
//

import Foundation

enum OpenCodeChatMapper {
    static func hydratedMessages(from messages: [OpenCodeSessionMessage]) -> [CodingAgentRuntimeHydratedMessage] {
        messages.compactMap { message in
            let text = renderedText(from: message.parts)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            return CodingAgentRuntimeHydratedMessage(
                runtimeMessageID: message.info.id,
                runtimePartIDs: message.parts.compactMap(\.payload.id),
                role: role(from: message.info.role),
                text: text,
                originalPayload: normalizedPayloadData(
                    type: message.info.role == "user" ? "user" : "assistant",
                    role: message.info.role ?? "assistant",
                    text: text,
                    sessionID: message.info.sessionID,
                    messageID: message.info.id,
                    partIDs: message.parts.compactMap(\.payload.id),
                    rawEvent: nil
                )
            )
        }
    }

    static func role(from rawRole: String?) -> MessageRole {
        rawRole == "user" ? .user : .assistant
    }

    static func renderedText(from parts: [OpenCodeMessagePart]) -> String {
        parts.compactMap { renderedText(from: $0) }.joined(separator: "\n")
    }

    static func renderedText(from part: OpenCodeMessagePart, delta: String? = nil, previous: String? = nil) -> String? {
        let payload = part.payload

        switch part {
        case .text, .reasoning:
            if let text = payload.text {
                return text
            }
            if let delta {
                return (previous ?? "") + delta
            }
            return previous

        case .tool:
            return toolText(from: payload)

        case .file:
            return titledText(
                title: "File",
                primary: payload.path ?? payload.url ?? payload.title ?? payload.source,
                body: payload.text
            )

        case .patch:
            return titledText(
                title: "Patch",
                primary: payload.path ?? payload.title,
                body: payload.text ?? payload.source
            )

        case .snapshot:
            return titledText(title: "Snapshot", primary: payload.title ?? payload.path, body: payload.text)

        case .stepStart:
            return titledText(title: "Step started", primary: payload.title, body: payload.text)

        case .stepFinish:
            return titledText(title: "Step finished", primary: payload.title, body: payload.text)

        case .agent:
            return titledText(title: "Agent", primary: payload.title ?? payload.tool, body: payload.text)

        case .subtask:
            return titledText(title: "Subtask", primary: payload.title ?? payload.tool, body: payload.text)

        case .retry:
            return titledText(title: "Retry", primary: payload.title, body: payload.text)

        case .compaction:
            return titledText(title: "Compaction", primary: payload.title, body: payload.text)

        case .unknown:
            return titledText(title: "OpenCode \(payload.type)", primary: payload.title, body: payload.text)
        }
    }

    static func normalizedPayloadData(
        type: String,
        role: String,
        text: String,
        sessionID: String?,
        messageID: String?,
        partIDs: [String],
        rawEvent: OpenCodeRawEvent?
    ) -> Data? {
        let block: [String: Any] = [
            "type": "text",
            "text": text
        ]

        var opencode: [String: Any] = [
            "partIDs": partIDs
        ]
        if let sessionID {
            opencode["sessionID"] = sessionID
        }
        if let messageID {
            opencode["messageID"] = messageID
        }

        var payload: [String: Any] = [
            "type": type,
            "message": [
                "role": role,
                "content": [block]
            ],
            "opencode": opencode
        ]

        if let rawEvent {
            payload["opencodeRawEvent"] = rawEvent.jsonObject
        }

        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    static func normalizedPayloadString(
        type: String,
        role: String,
        text: String,
        sessionID: String?,
        messageID: String?,
        partIDs: [String],
        rawEvent: OpenCodeRawEvent?
    ) -> String? {
        normalizedPayloadData(
            type: type,
            role: role,
            text: text,
            sessionID: sessionID,
            messageID: messageID,
            partIDs: partIDs,
            rawEvent: rawEvent
        ).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func providerMarker(from info: OpenCodeMessageInfo) -> String? {
        let providerID = info.providerID ?? info.model?.providerID
        let modelID = info.modelID ?? info.model?.modelID
        switch (providerID, modelID) {
        case let (provider?, model?):
            return "opencode:\(provider)/\(model)"
        case let (provider?, nil):
            return "opencode:\(provider)"
        case let (nil, model?):
            return "opencode:\(model)"
        case (nil, nil):
            return nil
        }
    }

    private static func toolText(from payload: OpenCodeMessagePartPayload) -> String {
        let name = payload.tool ?? payload.title ?? payload.callID ?? "tool"
        let status = payload.state?.status ?? "updated"
        var lines = ["Tool: \(name) (\(status))"]

        if let input = payload.input, let formatted = formatJSONObject(input.mapValues(\.value)) {
            lines.append("Input: \(formatted)")
        } else if let stateInput = payload.state?.input, let formatted = formatJSONObject(stateInput.mapValues(\.value)) {
            lines.append("Input: \(formatted)")
        }

        if let output = payload.output, let formatted = formatValue(output.value) {
            lines.append("Output: \(formatted)")
        } else if let stateOutput = payload.state?.output, let formatted = formatValue(stateOutput.value) {
            lines.append("Output: \(formatted)")
        }

        if let error = payload.error ?? payload.state?.error {
            lines.append("Error: \(error.message ?? error.name ?? "Tool failed")")
        }

        return lines.joined(separator: "\n")
    }

    private static func titledText(title: String, primary: String?, body: String?) -> String {
        var lines = [title]
        if let primary, !primary.isEmpty {
            lines[0] += ": \(primary)"
        }
        if let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(body)
        }
        return lines.joined(separator: "\n")
    }

    private static func formatJSONObject(_ object: [String: Any]) -> String? {
        formatValue(object)
    }

    private static func formatValue(_ value: Any) -> String? {
        if value is NSNull {
            return nil
        }
        if let string = value as? String {
            return string
        }
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return string
    }
}

struct OpenCodeChatEventAccumulator {
    private let sessionID: String
    private var rolesByMessageID: [String: String] = [:]
    private var providerByMessageID: [String: String] = [:]
    private var textByPartID: [String: String] = [:]
    private var partOrderByMessageID: [String: [String]] = [:]
    private var completedMessageIDs: Set<String> = []

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    mutating func consume(_ event: OpenCodeEvent) -> [MessageChunk] {
        switch event {
        case .messageUpdated(let properties, let raw):
            return consumeMessageUpdated(properties, raw: raw)
        case .messagePartUpdated(let properties, let raw):
            return consumeMessagePartUpdated(properties, raw: raw)
        case .sessionStatus(let properties, let raw):
            guard matches(properties.sessionID), properties.status.type == "idle" else { return [] }
            return [completionChunk(raw: raw)]
        case .sessionIdle(let properties, let raw):
            guard matches(properties.sessionID ?? properties.id) else { return [] }
            return [completionChunk(raw: raw)]
        case .sessionError(let properties, let raw):
            guard matches(properties.sessionID) else { return [] }
            return [errorChunk(message: properties.error.message ?? properties.error.name ?? "OpenCode session error.", raw: raw)]
        case .permissionUpdated(let properties, let raw):
            guard matches(properties.sessionID) else { return [] }
            return permissionChunks(properties, raw: raw)
        default:
            return []
        }
    }

    private mutating func consumeMessageUpdated(
        _ properties: OpenCodeMessageUpdatedProperties,
        raw: OpenCodeRawEvent
    ) -> [MessageChunk] {
        guard matches(properties.sessionID ?? properties.info.sessionID) else { return [] }
        rolesByMessageID[properties.info.id] = properties.info.role

        if let provider = OpenCodeChatMapper.providerMarker(from: properties.info) {
            providerByMessageID[properties.info.id] = provider
        }

        guard properties.info.role != "user",
              properties.info.time?.completed != nil else {
            return []
        }

        completedMessageIDs.insert(properties.info.id)
        return [completionChunk(messageID: properties.info.id, raw: raw)]
    }

    private mutating func consumeMessagePartUpdated(
        _ properties: OpenCodeMessagePartUpdatedProperties,
        raw: OpenCodeRawEvent
    ) -> [MessageChunk] {
        let payload = properties.part.payload
        guard matches(properties.sessionID ?? payload.sessionID),
              let messageID = payload.messageID else {
            return []
        }

        if rolesByMessageID[messageID] == "user" {
            return []
        }

        let partID = payload.id ?? "\(messageID):\(payload.type)"
        if partOrderByMessageID[messageID]?.contains(partID) != true {
            partOrderByMessageID[messageID, default: []].append(partID)
        }

        if let rendered = OpenCodeChatMapper.renderedText(
            from: properties.part,
            delta: properties.delta,
            previous: textByPartID[partID]
        ) {
            textByPartID[partID] = rendered
        }

        let content = content(for: messageID)
        guard !content.isEmpty else { return [] }

        return [chunk(
            content: content,
            isComplete: completedMessageIDs.contains(messageID),
            isError: false,
            raw: raw,
            messageID: messageID
        )]
    }

    private func completionChunk(messageID: String? = nil, raw: OpenCodeRawEvent) -> MessageChunk {
        let targetMessageID = messageID ?? latestAssistantMessageID()
        let renderedContent = targetMessageID.map { self.content(for: $0) } ?? ""
        return chunk(content: renderedContent, isComplete: true, isError: false, raw: raw, messageID: targetMessageID)
    }

    private func errorChunk(message: String, raw: OpenCodeRawEvent) -> MessageChunk {
        chunk(content: message, isComplete: true, isError: true, raw: raw, messageID: latestAssistantMessageID())
    }

    private func permissionChunks(_ properties: OpenCodePermissionProperties, raw: OpenCodeRawEvent) -> [MessageChunk] {
        let permissionID = properties.id ?? properties.permissionID
        guard let permissionID, !permissionID.isEmpty else { return [] }

        var input = properties.metadata?.mapValues(\.value) ?? [:]
        if let pattern = properties.pattern?.values, !pattern.isEmpty {
            input["pattern"] = pattern.joined(separator: ", ")
        }
        if let callID = properties.callID {
            input["callID"] = callID
        }

        var metadata: [String: Any] = [
            "type": "tool_permission",
            "runtime": CodingAgentRuntimeKind.openCode.rawValue,
            "permissionId": permissionID,
            "toolName": properties.title ?? properties.type ?? "OpenCode Tool",
            "input": input,
            "suggestions": properties.pattern?.values ?? []
        ]
        if let blockedPath = input["path"] as? String ?? input["file"] as? String ?? input["file_path"] as? String {
            metadata["blockedPath"] = blockedPath
        }
        if let original = OpenCodeChatMapper.normalizedPayloadString(
            type: "tool_permission",
            role: "assistant",
            text: properties.title ?? properties.type ?? "OpenCode permission request",
            sessionID: sessionID,
            messageID: properties.messageID,
            partIDs: [],
            rawEvent: raw
        ) {
            metadata["originalJSON"] = original
        }

        return [MessageChunk(content: "", isComplete: false, isError: false, metadata: metadata)]
    }

    private func chunk(
        content: String,
        isComplete: Bool,
        isError: Bool,
        raw: OpenCodeRawEvent,
        messageID: String?
    ) -> MessageChunk {
        let partIDs = messageID.flatMap { partOrderByMessageID[$0] } ?? []
        var metadata: [String: Any] = [
            "type": isComplete ? "result" : "assistant",
            "runtime": CodingAgentRuntimeKind.openCode.rawValue,
            "opencodeSessionId": sessionID,
            "content": [
                [
                    "type": "text",
                    "text": content
                ]
            ]
        ]

        if let messageID {
            metadata["opencodeMessageId"] = messageID
        }
        if !partIDs.isEmpty {
            metadata["opencodePartIds"] = partIDs
        }
        if let messageID, let provider = providerByMessageID[messageID] {
            metadata["runtimeProvider"] = provider
        }
        if isComplete {
            metadata["result"] = content
        }
        if let original = OpenCodeChatMapper.normalizedPayloadString(
            type: isComplete ? "result" : "assistant",
            role: "assistant",
            text: content,
            sessionID: sessionID,
            messageID: messageID,
            partIDs: partIDs,
            rawEvent: raw
        ) {
            metadata["originalJSON"] = original
        }

        return MessageChunk(content: content, isComplete: isComplete, isError: isError, metadata: metadata)
    }

    private func matches(_ candidate: String?) -> Bool {
        candidate == nil || candidate == sessionID
    }

    private func content(for messageID: String) -> String {
        let orderedPartIDs = partOrderByMessageID[messageID] ?? []
        return orderedPartIDs.compactMap { textByPartID[$0] }.joined(separator: "\n")
    }

    private func latestAssistantMessageID() -> String? {
        partOrderByMessageID.keys.sorted().last
    }
}

private extension OpenCodeRawEvent {
    var jsonObject: [String: Any] {
        [
            "type": type,
            "properties": properties.mapValues(\.value)
        ]
    }
}
