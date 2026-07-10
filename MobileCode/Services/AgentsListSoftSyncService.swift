//
//  AgentsListSoftSyncService.swift
//  CodeAgentsMobile
//
//  Purpose: Soft-poll OpenCode for new messages so unread badges and local
//  chat history stay current even when server push is disabled. Runs from the
//  Agents list and while any agent chat is open (background agents only).
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
    /// Absolute renderable assistant total after merge (for push/badge alignment).
    let absoluteAssistantCount: Int
    /// Latest non-empty assistant text for local notification preview.
    let latestAssistantPreview: String?
}

/// Pure unread-cursor math for soft polls (testable without SSH).
enum AgentsListUnreadCursor {
    /// Apply an **absolute** renderable-assistant total (aligned with push `renderable_assistant_count`).
    /// - Returns: `nil` when nothing should change.
    ///
    /// Rules:
    /// - First bind (no conversation yet): baseline known=read=absolute so history is not all unread.
    /// - Session change: reset read to 0, set known to absolute.
    /// - Same session: raise `lastKnown` when absolute is higher (never decrease).
    static func applyingAbsolute(
        lastKnown: Int,
        lastRead: Int,
        unreadConversationId: String?,
        sessionId: String,
        absoluteAssistantCount: Int
    ) -> (lastKnown: Int, lastRead: Int, unreadConversationId: String)? {
        let sessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty else { return nil }
        let absolute = max(0, absoluteAssistantCount)

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
                // Uninitialized unread state: treat current history as already seen.
                known = absolute
                read = absolute
                return (
                    lastKnown: known,
                    lastRead: read,
                    unreadConversationId: sessionId
                )
            }

            // Session pin moved: old cursors are meaningless for the new conversation.
            known = absolute
            read = 0
            return (
                lastKnown: known,
                lastRead: read,
                unreadConversationId: sessionId
            )
        }

        if absolute > known {
            known = absolute
            changed = true
        }

        guard changed else { return nil }
        return (lastKnown: known, lastRead: read, unreadConversationId: conversation ?? sessionId)
    }

    /// Legacy delta helper (tests + callers that only know newly inserted assistants).
    /// Prefer `applyingAbsolute` when a full local/remote total is available.
    static func applying(
        lastKnown: Int,
        lastRead: Int,
        unreadConversationId: String?,
        sessionId: String,
        newAssistantCount: Int
    ) -> (lastKnown: Int, lastRead: Int, unreadConversationId: String)? {
        let sessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty else { return nil }

        let known = max(0, lastKnown)
        let read = max(0, lastRead)
        var conversation = unreadConversationId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if conversation?.isEmpty == true {
            conversation = nil
        }

        // Convert delta into an absolute proposal: read + new (or absolute on session change).
        let proposedAbsolute: Int
        if conversation != sessionId {
            proposedAbsolute = max(0, newAssistantCount)
        } else {
            proposedAbsolute = max(known, read + max(0, newAssistantCount))
        }

        return applyingAbsolute(
            lastKnown: known,
            lastRead: read,
            unreadConversationId: conversation,
            sessionId: sessionId,
            absoluteAssistantCount: proposedAbsolute
        )
    }

    /// Cursor update after an interactive OpenCode reply fully finishes.
    ///
    /// Unlike soft-poll first-bind (history is treated as already seen), a finished
    /// reply while the user is **not** viewing the chat must leave at least the
    /// latest turn unread so list badges / app-icon counts stay honest.
    static func applyingInteractiveReplyFinished(
        lastKnown: Int,
        lastRead: Int,
        unreadConversationId: String?,
        sessionId: String,
        absoluteAssistantCount: Int,
        isViewingChat: Bool
    ) -> (lastKnown: Int, lastRead: Int, unreadConversationId: String)? {
        let sessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty else { return nil }
        let absolute = max(0, absoluteAssistantCount)

        var known = max(0, lastKnown)
        var read = max(0, lastRead)
        var conversation = unreadConversationId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if conversation?.isEmpty == true {
            conversation = nil
        }

        if let next = applyingAbsolute(
            lastKnown: known,
            lastRead: read,
            unreadConversationId: conversation,
            sessionId: sessionId,
            absoluteAssistantCount: absolute
        ) {
            known = next.lastKnown
            read = next.lastRead
            conversation = next.unreadConversationId
        } else {
            // Absolute did not raise known (already at total). Still bind session id.
            known = max(known, absolute)
            conversation = conversation ?? sessionId
        }

        if isViewingChat {
            // Live viewer: catch up read cursor so this agent does not badge itself.
            read = known
        } else {
            // Off-screen completion: never end at 0 unread when there is history.
            // First-bind baselining sets known==read; a finished reply must leave a gap.
            known = max(known, absolute)
            if known > 0, read >= known {
                read = known - 1
            }
        }

        return (
            lastKnown: known,
            lastRead: max(0, min(read, known)),
            unreadConversationId: conversation ?? sessionId
        )
    }
}

/// Soft-poll OpenCode chats for the Agents list.
@MainActor
final class AgentsListSoftSyncService {
    static let shared = AgentsListSoftSyncService()

    /// Per-project cooldown so reopening Agents is cheap.
    /// Short enough that leaving a chat mid-answer still surfaces badges within a turn.
    var messageCheckCooldown: TimeInterval = 15

    /// Bound remote history for list polls (recent turns only).
    var messageFetchLimit: Int = 50

    private var lastMessageCheckAt: [UUID: Date] = [:]
    private var inFlight = false
    private let runtimeRegistry = CodingAgentRuntimeRegistry()

    private init() {}

    /// Best-effort: hydrate new OpenCode messages into SwiftData and bump unread badges.
    /// - Parameters:
    ///   - projects: Agents to poll.
    ///   - modelContext: Persistence context for messages + unread cursors.
    ///   - excludingProjectID: Skip this agent (typically the open chat, which has its own hydrate).
    @discardableResult
    func softSyncMessages(
        projects: [RemoteProject],
        modelContext: ModelContext,
        excludingProjectID: UUID? = nil
    ) async -> [AgentsListMessageSyncResult] {
        guard !inFlight else { return [] }
        let targets = projects.filter { project in
            excludingProjectID == nil || project.id != excludingProjectID
        }
        guard !targets.isEmpty else {
            UnreadBadgeService.refreshAppIconBadge(using: modelContext)
            return []
        }

        inFlight = true
        defer { inFlight = false }

        var results: [AgentsListMessageSyncResult] = []
        let runtime = runtimeRegistry.runtime(for: .openCode)

        for project in targets {
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

                let previousUnread = project.unreadCount
                let applied = applyHydrationResult(
                    result,
                    project: project,
                    sessionId: sessionId,
                    modelContext: modelContext
                )
                results.append(applied)

                if applied.insertedMessages > 0 || applied.newAssistantMessages > 0 || applied.unreadCount != previousUnread {
                    SSHLogger.log(
                        "Agents soft message sync \(project.displayTitle): +\(applied.insertedMessages) msgs, +\(applied.newAssistantMessages) assistant, unread=\(applied.unreadCount)",
                        level: .info
                    )
                }

                // Surface a banner when soft-sync discovers new unread while the user is
                // not inside that chat (covers interactive replies when FCM was not used).
                if applied.unreadCount > previousUnread {
                    await PushNotificationsManager.shared.notifySoftSyncUnreadIncrease(
                        project: project,
                        previousUnread: previousUnread,
                        newUnread: applied.unreadCount,
                        preview: applied.latestAssistantPreview
                    )
                }
            } catch {
                // Still mark a short cooldown so a flaky project does not hammer SSH.
                lastMessageCheckAt[project.id] = Date().addingTimeInterval(-(messageCheckCooldown * 0.5))
                SSHLogger.log(
                    "Agents soft message sync failed \(project.displayTitle): \(error.localizedDescription)",
                    level: .warning
                )
            }
        }

        if !results.isEmpty {
            do {
                try modelContext.save()
            } catch {
                SSHLogger.log(
                    "Agents soft message sync save failed: \(error.localizedDescription)",
                    level: .warning
                )
            }
        }

        UnreadBadgeService.refreshAppIconBadge(using: modelContext)
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
                .map { OpenCodeChatMapper.normalizedUserPromptForDedupe($0.content) }
                .filter { !$0.isEmpty }
        )

        var inserted = 0
        var updated = 0
        var newAssistants = 0
        var allMessages = existingMessages

        for hydrated in result.hydratedMessages {
            let remoteCore = OpenCodeChatMapper.normalizedUserPromptForDedupe(hydrated.text)
            let merge = OpenCodeHydratedMessageMerge.action(
                for: hydrated,
                existingRuntimeMessageIDs: runtimeIDs,
                hasLocalUserMessage: hydrated.role == .user && (
                    remoteCore.isEmpty || localUserTexts.contains(remoteCore)
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
                    let wasEmpty = existing.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if !hydrated.text.isEmpty, existing.content != hydrated.text {
                        existing.content = hydrated.text
                        updated += 1
                        // Streaming placeholder → finished text: count as a new assistant for delta logs.
                        if existing.role == .assistant, wasEmpty {
                            newAssistants += 1
                        }
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
            allMessages.append(message)
            runtimeIDs.insert(hydrated.runtimeMessageID)
            project.noteLastMessage(at: message.timestamp)
            if hydrated.role == .user {
                let core = OpenCodeChatMapper.normalizedUserPromptForDedupe(hydrated.text)
                if !core.isEmpty {
                    localUserTexts.insert(core)
                }
            }
            inserted += 1
            if hydrated.role == .assistant,
               !hydrated.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                newAssistants += 1
            }
        }

        // Absolute total after merge — catches updates of already-inserted streaming placeholders
        // that the insert-only delta used to miss (leave chat mid-answer → no badge).
        let absoluteAssistants = UnreadBadgeMath.renderableAssistantCount(in: allMessages)
        let previousConversation = project.unreadConversationId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isUnreadUninitialized =
            (previousConversation == nil || previousConversation?.isEmpty == true)
            && project.lastKnownUnreadCursor == 0
            && project.lastReadUnreadCursor == 0

        if isUnreadUninitialized, newAssistants > 0, absoluteAssistants > 0 {
            // First soft-poll that also discovered new assistant content: baseline prior
            // history as read, but keep the newly discovered assistants as unread.
            project.unreadConversationId = sessionId
            project.lastKnownUnreadCursor = absoluteAssistants
            project.lastReadUnreadCursor = max(0, absoluteAssistants - newAssistants)
        } else if let cursors = AgentsListUnreadCursor.applyingAbsolute(
            lastKnown: project.lastKnownUnreadCursor,
            lastRead: project.lastReadUnreadCursor,
            unreadConversationId: project.unreadConversationId,
            sessionId: sessionId,
            absoluteAssistantCount: absoluteAssistants
        ) {
            project.lastKnownUnreadCursor = cursors.lastKnown
            project.lastReadUnreadCursor = cursors.lastRead
            project.unreadConversationId = cursors.unreadConversationId
        }

        // Unread/metadata updates must not reorder the Agents list.
        // Only real chat messages advance `lastMessageAt` (above).

        let latestPreview = allMessages
            .filter { $0.role == .assistant }
            .sorted { $0.timestamp < $1.timestamp }
            .last(where: { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .content

        return AgentsListMessageSyncResult(
            projectID: project.id,
            insertedMessages: inserted,
            updatedMessages: updated,
            newAssistantMessages: newAssistants,
            unreadCount: project.unreadCount,
            absoluteAssistantCount: absoluteAssistants,
            latestAssistantPreview: latestPreview
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
