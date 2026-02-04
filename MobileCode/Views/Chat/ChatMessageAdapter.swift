//
//  ChatMessageAdapter.swift
//  CodeAgentsMobile
//
//  Purpose: Adapt SwiftData Message models to ExyteChat messages.
//

import Foundation
import ExyteChat

struct ChatMessageAdapter {
    let exyteMessages: [ExyteChat.Message]
    private let messageById: [String: Message]

    init(
        messages: [Message],
        streamingMessageId: UUID?,
        streamingRedrawToken: UUID? = nil,
        currentUserName: String = "You",
        assistantName: String = "Claude"
    ) {
        let currentUser = User(id: "user", name: currentUserName, avatarURL: nil, type: .current)
        let assistantUser = User(id: "assistant", name: assistantName, avatarURL: nil, type: .other)
        var lookup: [String: Message] = [:]
        // ExyteChat uses `createdAt` for ordering. Keep it stable and based on the message timestamp.
        // Add a tiny event-id offset (when available) to break ties without affecting the displayed time.
        let eventIdEpsilon: TimeInterval = 0.000001

        self.exyteMessages = messages.compactMap { message in
            if ChatMessageAdapter.isSessionInfoMessage(message) {
                return nil
            }
            if ChatMessageAdapter.isSessionCompleteMessage(message) {
                return nil
            }
            let forceAssistant = ChatMessageAdapter.shouldForceAssistantRole(message)
            let isUser = message.role == .user && !forceAssistant
            let user = isUser ? currentUser : assistantUser
            let isStreaming = message.id == streamingMessageId
            let text: String = {
                if !message.content.isEmpty {
                    return message.content
                }

                if isStreaming {
                    return "..."
                }

                let structuredMessages = message.structuredMessages
                let structuredContent = message.structuredContent
                let hasStructuredContent = (structuredMessages?.isEmpty == false) || (structuredContent != nil)
                return ChatMessageAdapter.exyteMessageText(
                    for: message,
                    hasStructuredContent: hasStructuredContent,
                    structuredMessages: structuredMessages,
                    structuredContent: structuredContent,
                    isStreaming: false
                )
            }()
            let createdAt = message.timestamp.addingTimeInterval(
                TimeInterval(message.proxyEventId ?? 0) * eventIdEpsilon
            )
            var exyteMessage = ExyteChat.Message(
                id: message.id.uuidString,
                user: user,
                createdAt: createdAt,
                text: text
            )
            if isStreaming {
                exyteMessage.triggerRedraw = streamingRedrawToken
            }
            lookup[exyteMessage.id] = message
            return exyteMessage
        }

        self.messageById = lookup
    }

    func message(for exyteMessage: ExyteChat.Message) -> Message? {
        messageById[exyteMessage.id]
    }

    // MARK: - ExyteChat Text Sizing

    /// ExyteChat currently uses the message `text` for sizing/layout in some paths.
    /// If our message content is purely structured blocks (tool calls/results), `Message.content` can be empty,
    /// which leads to rows that are too small and clip our custom `MessageBubble` rendering.
    ///
    /// Provide a compact, multi-line summary for structured messages so the row has enough height.
    private static func exyteMessageText(
        for message: Message,
        hasStructuredContent: Bool,
        structuredMessages: [StructuredMessageContent]?,
        structuredContent: StructuredMessageContent?,
        isStreaming: Bool
    ) -> String {
        if !message.content.isEmpty {
            return message.content
        }

        if isStreaming {
            return "..."
        }

        if hasStructuredContent {
            if isSystemMessage(structuredMessages: structuredMessages, structuredContent: structuredContent) {
                return " "
            }
            if isResultMessage(structuredMessages: structuredMessages, structuredContent: structuredContent) {
                return " "
            }

            let blocks = previewBlocks(
                message: message,
                structuredMessages: structuredMessages,
                structuredContent: structuredContent
            )
            let preview = previewText(from: blocks)
            if !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return preview
            }
        }

        return " "
    }

    private static func isSystemMessage(
        structuredMessages: [StructuredMessageContent]?,
        structuredContent: StructuredMessageContent?
    ) -> Bool {
        if structuredContent?.type == "system" {
            return true
        }
        return structuredMessages?.contains { $0.type == "system" } ?? false
    }

    private static func isResultMessage(
        structuredMessages: [StructuredMessageContent]?,
        structuredContent: StructuredMessageContent?
    ) -> Bool {
        if structuredContent?.type == "result" {
            return true
        }
        return structuredMessages?.contains { $0.type == "result" } ?? false
    }

    private static func previewBlocks(
        message: Message,
        structuredMessages: [StructuredMessageContent]?,
        structuredContent: StructuredMessageContent?
    ) -> [ContentBlock] {
        if let structuredMessages = structuredMessages, !structuredMessages.isEmpty {
            let blocks = structuredMessages.compactMap { structured -> [ContentBlock]? in
                guard let content = structured.message else { return nil }
                switch content.content {
                case .blocks(let blocks):
                    return blocks
                case .text(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }
                    return [.text(TextBlock(type: "text", text: trimmed))]
                }
            }.flatMap { $0 }

            if !blocks.isEmpty {
                return blocks
            }
        }

        if let structured = structuredContent, let content = structured.message {
            switch content.content {
            case .blocks(let blocks):
                if !blocks.isEmpty {
                    return blocks
                }
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return [.text(TextBlock(type: "text", text: trimmed))]
                }
            }
        }

        return message.fallbackContentBlocks()
    }

    private static func previewText(from blocks: [ContentBlock]) -> String {
        let maxLines = 8
        let maxTextLength = 240
        var lines: [String] = []

        func appendLine(_ line: String) {
            guard lines.count < maxLines else { return }
            lines.append(line)
        }

        for block in blocks {
            guard lines.count < maxLines else { break }

            switch block {
            case .text(let textBlock):
                let trimmed = textBlock.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                appendLine(truncate(trimmed, maxLength: maxTextLength))

            case .toolUse(let toolUseBlock):
                if BlockFormattingUtils.isBlockedToolName(toolUseBlock.name) {
                    continue
                }
                appendLine("Tool: \(toolUseBlock.name)")
                if let summary = toolInputSummary(toolUseBlock.input) {
                    appendLine(summary)
                }
                appendLine("") // pad to approximate ToolUseView height

            case .toolResult(let toolResultBlock):
                if BlockFormattingUtils.isBlockedToolResultContent(toolResultBlock.content) {
                    continue
                }
                appendLine(toolResultBlock.isError ? "Tool Result (error)" : "Tool Result")
                let trimmed = toolResultBlock.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    appendLine(truncate(firstLine(trimmed), maxLength: maxTextLength))
                }
                appendLine("") // pad to approximate ToolResultView height

            case .unknown:
                continue
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func isSessionInfoMessage(_ message: Message) -> Bool {
        if let structured = message.structuredContent, structured.type == "system" {
            return true
        }
        if let structuredMessages = message.structuredMessages, !structuredMessages.isEmpty {
            let hasNonSystem = structuredMessages.contains { $0.type != "system" }
            return !hasNonSystem
        }
        return false
    }

    /// Result payloads (type=result) are metadata-only and should not be rendered as chat bubbles.
    /// We keep them in storage for debugging/sync, but hide them from the main chat UI.
    private static func isSessionCompleteMessage(_ message: Message) -> Bool {
        if let structured = message.structuredContent, structured.type == "result" {
            return true
        }
        if let structuredMessages = message.structuredMessages, !structuredMessages.isEmpty {
            let hasNonResult = structuredMessages.contains { $0.type != "result" }
            return !hasNonResult
        }
        return false
    }

    private static func shouldForceAssistantRole(_ message: Message) -> Bool {
        let blocks = previewBlocks(
            message: message,
            structuredMessages: message.structuredMessages,
            structuredContent: message.structuredContent
        )
        return blocks.contains { block in
            switch block {
            case .toolUse, .toolResult:
                return true
            case .text, .unknown:
                return false
            }
        }
    }

    private static func toolInputSummary(_ input: [String: Any]) -> String? {
        if let command = input["command"] as? String, !command.isEmpty {
            return truncate(command, maxLength: 120)
        }
        if let pattern = input["pattern"] as? String, !pattern.isEmpty {
            return "pattern: \(truncate(pattern, maxLength: 80))"
        }
        if let filePath = input["file_path"] as? String, !filePath.isEmpty {
            return "file: \(filePath)"
        }
        if input.isEmpty {
            return nil
        }
        return "\(input.count) parameter\(input.count == 1 ? "" : "s")"
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
    }

    private static func truncate(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let end = text.index(text.startIndex, offsetBy: maxLength)
        return String(text[..<end]) + "…"
    }
}
