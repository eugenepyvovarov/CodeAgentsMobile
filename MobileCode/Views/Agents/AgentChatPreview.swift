//
//  AgentChatPreview.swift
//  CodeAgentsMobile
//
//  Purpose: Last-message preview for the Agents chat list (Messages/Telegram style).
//

import Foundation
import SwiftData

/// Snapshot of the latest renderable chat turn for a list row.
struct AgentChatPreview: Equatable, Sendable {
    enum Sender: Equatable, Sendable {
        case you
        case agent
    }

    /// Visual cue for non-text progress (tool / think / read) in the list subtitle.
    enum Activity: Equatable, Sendable {
        case none
        case tools
        case thinking
        case reading
        case working
        case typing
        case attachment

        /// SF Symbol for the list preview leading icon (nil = plain text).
        var systemImage: String? {
            switch self {
            case .none:
                return nil
            case .tools:
                return "wrench.and.screwdriver.fill"
            case .thinking:
                return "brain.head.profile"
            case .reading:
                return "doc.text.magnifyingglass"
            case .working:
                return "ellipsis.circle"
            case .typing:
                return "ellipsis"
            case .attachment:
                return "paperclip"
            }
        }
    }

    let sender: Sender
    let body: String
    let timestamp: Date
    let isStreaming: Bool
    let activity: Activity

    /// Single-line list subtitle: "You: …" / body / activity placeholder.
    var listLine: String {
        if isStreaming, body.isEmpty, activity == .none || activity == .typing {
            return sender == .you ? "You: Sending…" : "Typing…"
        }
        switch sender {
        case .you:
            return activity == .none ? "You: \(body)" : body
        case .agent:
            return body
        }
    }
}

/// Pure text cleanup for list previews (testable without SwiftData).
enum AgentChatPreviewText {
    /// Collapse whitespace, strip UI blocks, map tool/progress noise to friendly copy.
    static func normalize(_ raw: String, maxLength: Int = 140) -> (body: String, activity: AgentChatPreview.Activity) {
        var text = raw
        text = stripCodeAgentsUIBlocks(from: text)
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else {
            return ("", .none)
        }

        if let classified = classifyProgress(collapsed) {
            return classified
        }

        if collapsed.count <= maxLength {
            return (collapsed, .none)
        }
        let end = collapsed.index(collapsed.startIndex, offsetBy: max(0, maxLength - 1))
        let truncated = String(collapsed[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        return (truncated, .none)
    }

    /// Map OpenCode progress strings (and similar) to short list labels.
    static func classifyProgress(_ text: String) -> (body: String, activity: AgentChatPreview.Activity)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        // "Using codeagents-scheduled-tasks_list_..." / "Using tools..."
        if lower.hasPrefix("using ") {
            return ("Using tools…", .tools)
        }
        // Bare snake_case tool ids sometimes land as content.
        if looksLikeToolIdentifier(trimmed) {
            return ("Using tools…", .tools)
        }
        if lower.hasPrefix("thinking") {
            return ("Thinking…", .thinking)
        }
        if lower.hasPrefix("reading ") || lower == "reading files..." || lower == "reading files…" {
            return ("Reading files…", .reading)
        }
        if lower.hasPrefix("editing ") {
            return ("Editing files…", .working)
        }
        if lower == "working..." || lower == "working…" || lower.hasPrefix("working with") {
            return ("Working…", .working)
        }
        if lower.hasPrefix("retrying") {
            return ("Retrying…", .working)
        }
        if lower.hasPrefix("condensing") || lower.hasPrefix("saving workspace") {
            return ("Working…", .working)
        }
        return nil
    }

    /// Heuristic: long snake_case / mcp-style ids without spaces.
    static func looksLikeToolIdentifier(_ text: String) -> Bool {
        guard text.count >= 18, !text.contains(" ") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return text.contains("_") || text.contains("-")
    }

    /// Remove ```codeagents-ui / codeagents_ui fenced blocks (render-only JSON).
    static func stripCodeAgentsUIBlocks(from text: String) -> String {
        let pattern = #"```(?:codeagents-ui|codeagents_ui)[\s\S]*?```"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
}

/// Messages-style relative timestamps for chat list rows.
enum AgentChatListTimestamp {
    static func format(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: now),
           date >= weekAgo {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}

/// Load the latest useful message for an agent from SwiftData.
enum AgentChatPreviewLoader {
    @MainActor
    static func load(
        projectId: UUID,
        in context: ModelContext
    ) -> AgentChatPreview? {
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { message in
                message.projectId == projectId
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        // Skip a few empty/error shells to find a real preview.
        descriptor.fetchLimit = 12

        let messages = (try? context.fetch(descriptor)) ?? []
        for message in messages {
            if message.presentsAsLocalError { continue }

            let normalized = AgentChatPreviewText.normalize(message.content)
            let hasAttachments = message.hasChatAttachments
            let isStreaming = message.isStreaming && !message.isComplete

            if normalized.body.isEmpty, !hasAttachments, !isStreaming {
                continue
            }

            let body: String
            let activity: AgentChatPreview.Activity
            if !normalized.body.isEmpty {
                body = normalized.body
                activity = normalized.activity
            } else if hasAttachments {
                body = "Attachment"
                activity = .attachment
            } else if isStreaming {
                body = ""
                activity = .typing
            } else {
                continue
            }

            let sender: AgentChatPreview.Sender = message.role == .user ? .you : .agent
            return AgentChatPreview(
                sender: sender,
                body: body,
                timestamp: message.timestamp,
                isStreaming: isStreaming,
                activity: activity
            )
        }
        return nil
    }
}
