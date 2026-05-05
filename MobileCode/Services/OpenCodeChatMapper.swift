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
        case .text:
            if let text = payload.text {
                return text
            }
            if let delta {
                return (previous ?? "") + delta
            }
            return previous

        case .reasoning,
             .tool,
             .file,
             .patch,
             .snapshot,
             .stepStart,
             .stepFinish,
             .agent,
             .subtask,
             .retry,
             .compaction,
             .unknown:
            return nil
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

    static func normalizedPayloadData(
        type: String,
        role: String,
        contentBlocks: [[String: Any]],
        sessionID: String?,
        messageID: String?,
        partIDs: [String],
        rawEvent: OpenCodeRawEvent?
    ) -> Data? {
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
                "content": contentBlocks
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

    static func normalizedPayloadString(
        type: String,
        role: String,
        contentBlocks: [[String: Any]],
        sessionID: String?,
        messageID: String?,
        partIDs: [String],
        rawEvent: OpenCodeRawEvent?
    ) -> String? {
        normalizedPayloadData(
            type: type,
            role: role,
            contentBlocks: contentBlocks,
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
            return completionChunksIfReady(raw: raw)
        case .sessionIdle(let properties, let raw):
            guard matches(properties.sessionID ?? properties.id) else { return [] }
            return completionChunksIfReady(raw: raw)
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
        let content = content(for: properties.info.id)
        guard !content.isEmpty else {
            return []
        }
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

        if case .tool = properties.part {
            return toolChunks(for: properties.part, raw: raw, messageID: messageID, partID: partID)
        }

        let content = content(for: messageID)
        guard !content.isEmpty else {
            guard let progress = progressText(for: properties.part) else { return [] }
            return [progressChunk(content: progress, raw: raw, messageID: messageID)]
        }

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

    private func completionChunksIfReady(raw: OpenCodeRawEvent) -> [MessageChunk] {
        guard let messageID = latestAssistantMessageID() else { return [] }
        let renderedContent = content(for: messageID)

        if !renderedContent.isEmpty || completedMessageIDs.contains(messageID) {
            return [completionChunk(messageID: messageID, raw: raw)]
        }

        return []
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

    private func progressText(for part: OpenCodeMessagePart) -> String? {
        let payload = part.payload

        switch part {
        case .reasoning:
            return "Thinking..."
        case .tool:
            let toolName = payload.state?.title ?? payload.title ?? payload.tool
            if let toolName, !toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Using \(toolName)..."
            }
            return "Using tools..."
        case .file:
            if let path = payload.path, !path.isEmpty {
                return "Reading \(URL(fileURLWithPath: path).lastPathComponent)..."
            }
            return "Reading files..."
        case .patch:
            return "Editing files..."
        case .stepStart:
            return payload.title ?? "Working..."
        case .stepFinish:
            return "Finishing step..."
        case .agent, .subtask:
            return payload.title ?? "Working with a subtask..."
        case .retry:
            return "Retrying..."
        case .compaction:
            return "Condensing context..."
        case .snapshot:
            return "Saving workspace state..."
        case .text, .unknown:
            return nil
        }
    }

    private func toolChunks(
        for part: OpenCodeMessagePart,
        raw: OpenCodeRawEvent,
        messageID: String,
        partID: String
    ) -> [MessageChunk] {
        let payload = part.payload
        let toolUseID = payload.callID?.nonEmptyValue ?? payload.id?.nonEmptyValue ?? partID
        let toolName = payload.state?.title?.nonEmptyValue
            ?? payload.title?.nonEmptyValue
            ?? payload.tool?.nonEmptyValue
            ?? payload.type
        let input = payload.input?.mapValues(\.value)
            ?? payload.state?.input?.mapValues(\.value)
            ?? [:]
        let status = payload.state?.status.lowercased() ?? "running"
        let output = payload.output?.value ?? payload.state?.output?.value
        let errorMessage = payload.error?.message ?? payload.state?.error?.message
        let isError = errorMessage != nil || ["error", "failed", "failure"].contains(status)

        var blocks: [[String: Any]] = [
            [
                "type": "tool_use",
                "id": toolUseID,
                "name": toolName,
                "input": input
            ]
        ]

        if let outputText = toolResultText(output: output, errorMessage: errorMessage) {
            blocks.append([
                "type": "tool_result",
                "tool_use_id": toolUseID,
                "content": outputText,
                "is_error": isError
            ])
        }

        var metadata: [String: Any] = [
            "type": "opencode_tool",
            "runtime": CodingAgentRuntimeKind.openCode.rawValue,
            "opencodeSessionId": sessionID,
            "opencodeMessageId": messageID,
            "opencodePartIds": [partID],
            "toolPartID": partID,
            "toolCallID": toolUseID,
            "toolName": toolName,
            "toolStatus": status,
            "content": blocks,
            "opencodeRawEvent": raw.jsonObject
        ]

        if let provider = providerByMessageID[messageID] {
            metadata["runtimeProvider"] = provider
        }
        if let original = OpenCodeChatMapper.normalizedPayloadString(
            type: "assistant",
            role: "assistant",
            contentBlocks: blocks,
            sessionID: sessionID,
            messageID: messageID,
            partIDs: [partID],
            rawEvent: raw
        ) {
            metadata["originalJSON"] = original
        }

        let summary = toolSummary(toolName: toolName, status: status, isError: isError, hasOutput: blocks.count > 1)
        let isComplete = blocks.count > 1 || ["completed", "complete", "done", "success", "error", "failed", "failure"].contains(status)
        return [MessageChunk(content: summary, isComplete: isComplete, isError: isError, metadata: metadata)]
    }

    private func toolSummary(toolName: String, status: String, isError: Bool, hasOutput: Bool) -> String {
        if isError {
            return "\(toolName) failed"
        }
        if hasOutput || ["completed", "complete", "done", "success"].contains(status) {
            return "\(toolName) completed"
        }
        return "Using \(toolName)..."
    }

    private func toolResultText(output: Any?, errorMessage: String?) -> String? {
        if let errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        guard let output else { return nil }
        if output is NSNull {
            return nil
        }
        if let string = output as? String {
            return string.isEmpty ? nil : string
        }
        if JSONSerialization.isValidJSONObject(output),
           let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return String(describing: output)
    }

    private func progressChunk(content: String, raw: OpenCodeRawEvent, messageID: String?) -> MessageChunk {
        var metadata: [String: Any] = [
            "type": "opencode_progress",
            "runtime": CodingAgentRuntimeKind.openCode.rawValue,
            "opencodeSessionId": sessionID,
            "progress": content
        ]

        if let messageID {
            metadata["opencodeMessageId"] = messageID
        }
        if let messageID, let provider = providerByMessageID[messageID] {
            metadata["runtimeProvider"] = provider
        }

        metadata["opencodeRawEvent"] = raw.jsonObject
        return MessageChunk(content: content, isComplete: false, isError: false, metadata: metadata)
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
            type: "assistant",
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
        candidate == sessionID
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

private extension String {
    var nonEmptyValue: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
