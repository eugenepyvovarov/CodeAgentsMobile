//
//  AgentsListSoftSyncService.swift
//  CodeAgentsMobile
//
//  Purpose: While the Agents list is visible, soft-poll OpenCode for new
//  messages so unread badges and local chat history stay current even when
//  server push is disabled.
//

import Foundation
import SwiftData

/// Result of a soft message poll for one agent.
struct AgentsListMessageSyncResult: Equatable {
    let projectID: UUID
    let insertedMessages: Int
    let updatedMessages: Int
    let newAssistantMessages: Int
    let unreadCount: Int
}

/// Pure unread-cursor math for soft polls (testable without SSH).
enum AgentsListUnreadCursor {
    /// Apply newly discovered renderable assistant messages to unread cursors.
    /// - Returns: `nil` when nothing should change.
    ///
    /// Rules (aligned with push unread handling):
    /// - Same session: bump `lastKnown` by newly inserted assistant count above `lastRead`.
    /// - Session change: reset both cursors, then apply the new assistant count.
    /// - First bind with uninitialized cursors: baseline so existing history is not all unread.
    static func applying(
        lastKnown: Int,
        lastRead: Int,
        unreadConversationId: String?,
        sessionId: String,
        newAssistantCount: Int
    ) -> (lastKnown: Int, lastRead: Int, unreadConversationId: String)? {
        let sessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty else { return nil }

        var known = max(0, lastKnown)
        var read = max(0, lastRead)
        var conversation = unreadConversationId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if conversation?.isEmpty == true {
            conversation = nil
        }
        var changed = false

        if conversation != sessionId {
            let isFirstBind = conversation == nil
            conversation = sessionId
            changed = true

            if isFirstBind {
                // Uninitialized unread state: treat newly hydrated history as already seen
                // so the first soft poll does not paint every agent with a huge badge.
                if known == 0, read == 0, newAssistantCount > 0 {
                    known = newAssistantCount
                    read = newAssistantCount
                    return (
                        lastKnown: known,
                        lastRead: read,
                        unreadConversationId: sessionId
                    )
                }
            } else {
                // Session pin moved: old cursors are meaningless for the new conversation.
                known = 0
                read = 0
            }
        }

        if newAssistantCount > 0 {
            let proposed = read + newAssistantCount
            if proposed > known {
                known = proposed
                changed = true
            }
        }

        guard changed else { return nil }
        return (lastKnown: known, lastRead: read, unreadConversationId: conversation ?? sessionId)
    }
}

/// Soft-poll OpenCode chats for the Agents list.
@MainActor
final class AgentsListSoftSyncService {
    static let shared = AgentsListSoftSyncService()

    /// Per-project cooldown so reopening Agents is cheap.
    var messageCheckCooldown: TimeInterval = 60

    /// Bound remote history for list polls (recent turns only).
    var messageFetchLimit: Int = 50

    private var lastMessageCheckAt: [UUID: Date] = [:]
    private var inFlight = false
    private let runtimeRegistry = CodingAgentRuntimeRegistry()

    private init() {}

    /// Best-effort: hydrate new OpenCode messages into SwiftData and bump unread badges.
    @discardableResult
    func softSyncMessages(
        projects: [RemoteProject],
        modelContext: ModelContext
    ) async -> [AgentsListMessageSyncResult] {
        guard !inFlight else { return [] }
        guard !projects.isEmpty else { return [] }

        inFlight = true
        defer { inFlight = false }

        var results: [AgentsListMessageSyncResult] = []
        let runtime = runtimeRegistry.runtime(for: .openCode)

        for project in projects {
            guard CodingAgentRuntimeResolver.runtimeKind(for: project) == .openCode else { continue }
            guard let sessionId = project.openCodeSessionId?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !sessionId.isEmpty else {
                continue
            }

            if let last = lastMessageCheckAt[project.id],
               Date().timeIntervalSince(last) < messageCheckCooldown {
                continue
            }

            do {
                let result = try await runtime.hydrateMessages(
                    for: project,
                    mode: .initialBounded(limit: messageFetchLimit)
                )
                lastMessageCheckAt[project.id] = Date()

                let applied = applyHydrationResult(
                    result,
                    project: project,
                    sessionId: sessionId,
                    modelContext: modelContext
                )
                results.append(applied)

                if applied.insertedMessages > 0 || applied.newAssistantMessages > 0 {
                    SSHLogger.log(
                        "Agents-list soft message sync \(project.displayTitle): +\(applied.insertedMessages) msgs, +\(applied.newAssistantMessages) assistant, unread=\(applied.unreadCount)",
                        level: .info
                    )
                }
            } catch {
                // Still mark a short cooldown so a flaky project does not hammer SSH.
                lastMessageCheckAt[project.id] = Date().addingTimeInterval(-(messageCheckCooldown * 0.5))
                SSHLogger.log(
                    "Agents-list soft message sync failed \(project.displayTitle): \(error.localizedDescription)",
                    level: .warning
                )
            }
        }

        if !results.isEmpty {
            do {
                try modelContext.save()
            } catch {
                SSHLogger.log(
                    "Agents-list soft message sync save failed: \(error.localizedDescription)",
                    level: .warning
                )
            }
        }

        return results
    }

    // MARK: - Internals

    private func applyHydrationResult(
        _ result: OpenCodeHydrationResult,
        project: RemoteProject,
        sessionId: String,
        modelContext: ModelContext
    ) -> AgentsListMessageSyncResult {
        let projectId = project.id
        let existingMessages = (try? modelContext.fetch(
            FetchDescriptor<Message>(
                predicate: #Predicate { message in
                    message.projectId == projectId
                }
            )
        )) ?? []

        var runtimeIDs = Set(existingMessages.compactMap(Self.runtimeMessageID(from:)))
        var localUserTexts = Set(
            existingMessages
                .filter { $0.role == .user }
                .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        var inserted = 0
        var updated = 0
        var newAssistants = 0

        for hydrated in result.hydratedMessages {
            let merge = OpenCodeHydratedMessageMerge.action(
                for: hydrated,
                existingRuntimeMessageIDs: runtimeIDs,
                hasLocalUserMessage: localUserTexts.contains(
                    hydrated.text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )

            switch merge {
            case .skipLocalUserDuplicate:
                runtimeIDs.insert(hydrated.runtimeMessageID)
                continue
            case .updateExisting:
                if let existing = existingMessages.first(where: {
                    Self.runtimeMessageID(from: $0) == hydrated.runtimeMessageID
                }) {
                    if !hydrated.text.isEmpty, existing.content != hydrated.text {
                        existing.content = hydrated.text
                        updated += 1
                    }
                    if let payload = hydrated.originalPayload {
                        existing.originalJSON = payload
                    }
                    existing.isComplete = true
                    existing.isStreaming = false
                }
                runtimeIDs.insert(hydrated.runtimeMessageID)
                continue
            case .insert:
                break
            }

            let message = Message(
                content: hydrated.text,
                role: hydrated.role,
                projectId: projectId,
                originalJSON: hydrated.originalPayload,
                isComplete: true,
                isStreaming: false
            )
            if let createdAt = hydrated.createdAt {
                message.timestamp = createdAt
            }
            modelContext.insert(message)
            runtimeIDs.insert(hydrated.runtimeMessageID)
            if hydrated.role == .user {
                let trimmed = hydrated.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    localUserTexts.insert(trimmed)
                }
            }
            inserted += 1
            if hydrated.role == .assistant,
               !hydrated.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                newAssistants += 1
            }
        }

        if let cursors = AgentsListUnreadCursor.applying(
            lastKnown: project.lastKnownUnreadCursor,
            lastRead: project.lastReadUnreadCursor,
            unreadConversationId: project.unreadConversationId,
            sessionId: sessionId,
            newAssistantCount: newAssistants
        ) {
            project.lastKnownUnreadCursor = cursors.lastKnown
            project.lastReadUnreadCursor = cursors.lastRead
            project.unreadConversationId = cursors.unreadConversationId
        }

        if inserted > 0 || updated > 0 || newAssistants > 0 {
            project.updateLastModified()
        }

        return AgentsListMessageSyncResult(
            projectID: project.id,
            insertedMessages: inserted,
            updatedMessages: updated,
            newAssistantMessages: newAssistants,
            unreadCount: project.unreadCount
        )
    }

    /// Extract OpenCode message id embedded in stored originalJSON (same shape as chat hydration).
    static func runtimeMessageID(from message: Message) -> String? {
        guard let originalJSON = message.originalJSON,
              let raw = String(data: originalJSON, encoding: .utf8) else {
            return nil
        }

        for line in raw.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let opencode = json["opencode"] as? [String: Any],
                  let messageID = opencode["messageID"] as? String,
                  !messageID.isEmpty else {
                continue
            }
            return messageID
        }
        return nil
    }

    #if DEBUG
    func resetThrottlesForTesting() {
        lastMessageCheckAt.removeAll()
        inFlight = false
    }
    #endif
}
