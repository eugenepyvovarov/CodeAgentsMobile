//
//  UnreadBadgeService.swift
//  CodeAgentsMobile
//
//  Purpose: Aggregate agent unread cursors into list badges and the app icon badge.
//

import Foundation
import SwiftData
import UserNotifications

extension Notification.Name {
    /// Posted after unread cursors change (push, soft sync, mark-as-read).
    /// userInfo may include `total` (Int) app-icon total.
    static let agentsUnreadDidChange = Notification.Name("agentsUnreadDidChange")
}

enum OpenCodeUnreadCursorSchema {
    /// v2 counts unique finalized OpenCode assistant runtime message IDs per session.
    static let currentVersion = 2
}

/// Pure totals for unread badges (unit-testable without UIKit).
enum UnreadBadgeMath {
    /// Sum of per-agent unread counts, optionally excluding one project (e.g. the open chat).
    static func totalUnread(
        projectUnreads: [(id: UUID, unread: Int)],
        excludingProjectID: UUID? = nil
    ) -> Int {
        projectUnreads.reduce(0) { partial, entry in
            if let excludingProjectID, entry.id == excludingProjectID {
                return partial
            }
            return partial + max(0, entry.unread)
        }
    }

    static func badgeText(for count: Int) -> String? {
        guard count > 0 else { return nil }
        if count >= 100 {
            return "99+"
        }
        return "\(count)"
    }

    /// Count non-empty assistant bubbles (soft-sync / interactive completion).
    /// Prefer structured content when present; fall back to plain text.
    static func renderableAssistantCount(in messages: [Message]) -> Int {
        renderableAssistantMessages(in: messages).count
    }

    /// Canonical unread cursor unit shared by live streaming, hydration, and the daemon:
    /// one unique finalized OpenCode assistant runtime message in the active session.
    /// A single runtime message can produce several local tool/text rows, so UI rows
    /// must never be used as the cross-device cursor.
    static func finalizedOpenCodeAssistantCount(in messages: [Message], sessionID: String) -> Int {
        finalizedOpenCodeAssistantMessageIDs(in: messages, sessionID: sessionID).count
    }

    static func finalizedOpenCodeAssistantMessageIDs(
        in messages: [Message],
        sessionID: String
    ) -> Set<String> {
        guard let sessionID = OpenCodeSessionID.sanitize(sessionID) else { return [] }
        return Set(messages.compactMap { message in
            guard isFinalizedOpenCodeAssistant(message, sessionID: sessionID) else { return nil }
            return OpenCodePersistedMessageMetadata.runtimeMessageID(from: message)
        })
    }

    /// App notices are assistant-colored rows but never proof that a remote OpenCode
    /// reply hydrated. Require a finalized row carrying runtime + session metadata.
    static func isFinalizedOpenCodeAssistant(_ message: Message, sessionID: String) -> Bool {
        guard message.role == .assistant,
              !message.isLocalError,
              message.isComplete,
              !message.isStreaming,
              message.openCodeRuntimeFinalized,
              OpenCodePersistedMessageMetadata.hasRenderableAssistantText(message),
              OpenCodePersistedMessageMetadata.runtimeMessageID(from: message) != nil,
              let expectedSessionID = OpenCodeSessionID.sanitize(sessionID),
              let messageSessionID = OpenCodeSessionID.sanitize(
                  OpenCodePersistedMessageMetadata.sessionID(from: message)
              ) else {
            return false
        }
        return messageSessionID == expectedSessionID
    }

    private static func renderableAssistantMessages(in messages: [Message]) -> [Message] {
        messages.filter { message in
            guard message.role == .assistant else { return false }
            if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            // Tool-only assistant rows still count as a bubble once complete.
            return message.isComplete && message.originalJSON != nil
        }
    }
}

/// Applies app-icon badge and broadcasts unread changes for in-app chrome.
@MainActor
enum UnreadBadgeService {
    /// Total unread across all agents in the store.
    static func totalUnreadCount(
        in context: ModelContext,
        excludingProjectID: UUID? = nil
    ) -> Int {
        let projects = (try? context.fetch(FetchDescriptor<RemoteProject>())) ?? []
        return UnreadBadgeMath.totalUnread(
            projectUnreads: projects.map { ($0.id, $0.unreadCount) },
            excludingProjectID: excludingProjectID
        )
    }

    /// Recompute and apply the home-screen app icon badge from SwiftData.
    static func refreshAppIconBadge(using context: ModelContext) {
        let total = totalUnreadCount(in: context)
        applyAppIconBadge(total)
        NotificationCenter.default.post(
            name: .agentsUnreadDidChange,
            object: nil,
            userInfo: ["total": total]
        )
    }

    /// Set the OS app icon badge to an absolute count.
    static func applyAppIconBadge(_ total: Int) {
        let value = max(0, total)
        Task {
            do {
                try await UNUserNotificationCenter.current().setBadgeCount(value)
            } catch {
                #if DEBUG
                SSHLogger.log(
                    "setBadgeCount failed for total=\(value): \(error.localizedDescription)",
                    level: .warning
                )
                #endif
            }
        }
    }
}
