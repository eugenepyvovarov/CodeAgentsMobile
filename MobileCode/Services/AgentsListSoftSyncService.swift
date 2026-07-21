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
    /// reply whose final output was not actually seen must leave at least the latest
    /// turn unread so list badges / app-icon counts stay honest. Chat selection alone
    /// is not sufficient evidence that the final output was seen.
    static func applyingInteractiveReplyFinished(
        lastKnown: Int,
        lastRead: Int,
        unreadConversationId: String?,
        sessionId: String,
        absoluteAssistantCount: Int,
        wasFinalOutputSeen: Bool
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

        if wasFinalOutputSeen {
            // Seeing this completion proves only the supplied absolute count was read.
            // `known` may already include a newer reply learned from another device.
            read = max(read, min(absolute, known))
        } else {
            // Unseen completion: never end at 0 unread when there is history.
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

enum AgentsListAssistantFinality {
    /// Keep migration unread detection scoped to IDs observed by the initial bounded poll.
    /// Hydrated IDs let a reply inserted incomplete on poll N count when it finishes on poll N+1.
    static func migrationBoundedCandidateRuntimeMessageIDs(
        isCursorMigration: Bool,
        previousHydrationMessageIDs: Set<String>,
        initialBoundedAddedMessageIDs: Set<String>,
        initialBoundedHydratedMessageIDs: Set<String>
    ) -> Set<String> {
        guard isCursorMigration, !previousHydrationMessageIDs.isEmpty else {
            return []
        }
        return initialBoundedAddedMessageIDs.union(initialBoundedHydratedMessageIDs)
    }

    static func shouldCountAsNew(
        runtimeMessageID: String,
        existedBeforeHydration: Bool,
        wasRuntimeFinalized: Bool,
        wasLocallyIncompleteOrStreaming: Bool,
        hydratedRole: MessageRole,
        hydratedIsComplete: Bool,
        hydratedText: String,
        isCursorMigration: Bool,
        migrationBoundedCandidateRuntimeMessageIDs: Set<String>
    ) -> Bool {
        guard hydratedRole == .assistant,
              hydratedIsComplete,
              !hydratedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if isCursorMigration {
            guard migrationBoundedCandidateRuntimeMessageIDs.contains(runtimeMessageID) else {
                return false
            }
            return !existedBeforeHydration || wasLocallyIncompleteOrStreaming
        }
        return !existedBeforeHydration || !wasRuntimeFinalized
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
                let initialBoundedResult = try await runtime.hydrateMessages(
                    for: project,
                    mode: .initialBounded(limit: messageFetchLimit)
                )
                let isCursorMigration =
                    project.unreadCursorVersion != OpenCodeUnreadCursorSchema.currentVersion
                let migrationBoundedCandidateIDs =
                    AgentsListAssistantFinality.migrationBoundedCandidateRuntimeMessageIDs(
                        isCursorMigration: isCursorMigration,
                        previousHydrationMessageIDs: initialBoundedResult.previousState.messageIDs,
                        initialBoundedAddedMessageIDs: initialBoundedResult.diff.addedMessageIDs,
                        initialBoundedHydratedMessageIDs: Set(
                            initialBoundedResult.hydratedMessages.map(\.runtimeMessageID)
                        )
                    )
                var result = initialBoundedResult
                // A full page is not proof of an absolute session total. When the
                // bounded poll sees a newly finalized reply, pay for one unbounded
                // snapshot before changing the cross-device unread cursor.
                if result.canonicalAssistantCount == nil,
                   result.hydratedMessages.contains(where: {
                       $0.role == .assistant && $0.isComplete
                           && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                   }) {
                    result = try await runtime.hydrateMessages(for: project, mode: .fullRefresh)
                }
                lastMessageCheckAt[project.id] = Date()

                let previousUnread = project.unreadCount
                let applied = applyHydrationResult(
                    result,
                    project: project,
                    sessionId: sessionId,
                    migrationBoundedCandidateRuntimeMessageIDs: migrationBoundedCandidateIDs,
                    modelContext: modelContext
                )
                // Persist merged rows/cursors before advancing hydration anchors. If
                // the app dies between these saves, the next poll safely repeats work
                // instead of leaving anchors ahead of durable messages.
                try modelContext.save()
                let previousHydrationState = project.openCodeHydrationState
                project.updateOpenCodeHydrationState(
                    result.storedState,
                    updateModifiedTimestamp: false
                )
                do {
                    try modelContext.save()
                } catch {
                    project.updateOpenCodeHydrationState(
                        previousHydrationState,
                        updateModifiedTimestamp: false
                    )
                    SSHLogger.log(
                        "Agents soft message sync anchor save failed: \(error.localizedDescription)",
                        level: .warning
                    )
                }
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

        UnreadBadgeService.refreshAppIconBadge(using: modelContext)
        return results
    }

    // MARK: - Internals

    private func applyHydrationResult(
        _ result: OpenCodeHydrationResult,
        project: RemoteProject,
        sessionId: String,
        migrationBoundedCandidateRuntimeMessageIDs: Set<String>,
        modelContext: ModelContext
    ) -> AgentsListMessageSyncResult {
        let projectId = project.id
        let isCursorMigration = project.unreadCursorVersion != OpenCodeUnreadCursorSchema.currentVersion
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
                    let wasRuntimeFinalized = existing.openCodeRuntimeFinalized
                    let wasLocallyIncompleteOrStreaming = !existing.isComplete || existing.isStreaming
                    if !hydrated.text.isEmpty, existing.content != hydrated.text {
                        existing.content = hydrated.text
                        updated += 1
                    }
                    if let payload = hydrated.originalPayload {
                        existing.originalJSON = payload
                    }
                    existing.isComplete = hydrated.isComplete
                    existing.isStreaming = !hydrated.isComplete
                    existing.openCodeRuntimeFinalized = hydrated.isComplete
                    if AgentsListAssistantFinality.shouldCountAsNew(
                        runtimeMessageID: hydrated.runtimeMessageID,
                        existedBeforeHydration: true,
                        wasRuntimeFinalized: wasRuntimeFinalized,
                        wasLocallyIncompleteOrStreaming: wasLocallyIncompleteOrStreaming,
                        hydratedRole: hydrated.role,
                        hydratedIsComplete: hydrated.isComplete,
                        hydratedText: hydrated.text,
                        isCursorMigration: isCursorMigration,
                        migrationBoundedCandidateRuntimeMessageIDs: migrationBoundedCandidateRuntimeMessageIDs
                    ) {
                        newAssistants += 1
                    }
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
                isComplete: hydrated.isComplete,
                isStreaming: !hydrated.isComplete
            )
            if let createdAt = hydrated.createdAt {
                message.timestamp = createdAt
            }
            message.openCodeRuntimeFinalized = hydrated.isComplete
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
            if AgentsListAssistantFinality.shouldCountAsNew(
                runtimeMessageID: hydrated.runtimeMessageID,
                existedBeforeHydration: false,
                wasRuntimeFinalized: false,
                wasLocallyIncompleteOrStreaming: false,
                hydratedRole: hydrated.role,
                hydratedIsComplete: hydrated.isComplete,
                hydratedText: hydrated.text,
                isCursorMigration: isCursorMigration,
                migrationBoundedCandidateRuntimeMessageIDs: migrationBoundedCandidateRuntimeMessageIDs
            ) {
                newAssistants += 1
            }
        }

        // Only a fetch known to cover the entire session can move the v2 absolute
        // cursor. Never relabel a bounded local merge as a cross-device total.
        if let absoluteAssistants = result.canonicalAssistantCount {
            if project.unreadCursorVersion != OpenCodeUnreadCursorSchema.currentVersion {
                project.unreadCursorVersion = OpenCodeUnreadCursorSchema.currentVersion
                project.unreadConversationId = nil
                project.lastKnownUnreadCursor = 0
                project.lastReadUnreadCursor = 0
            }

            let previousConversation = project.unreadConversationId?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isUnreadUninitialized =
                (previousConversation == nil || previousConversation?.isEmpty == true)
                && project.lastKnownUnreadCursor == 0
                && project.lastReadUnreadCursor == 0

            if isUnreadUninitialized, newAssistants > 0, absoluteAssistants > 0 {
                // First canonical poll that also discovered new finalized content:
                // baseline older history as read while keeping the new replies unread.
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
        }

        // Unread/metadata updates must not reorder the Agents list.
        // Only real chat messages advance `lastMessageAt` (above).

        let latestPreview = allMessages
            .filter { UnreadBadgeMath.isFinalizedOpenCodeAssistant($0, sessionID: sessionId) }
            .sorted { $0.timestamp < $1.timestamp }
            .last(where: { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .content

        return AgentsListMessageSyncResult(
            projectID: project.id,
            insertedMessages: inserted,
            updatedMessages: updated,
            newAssistantMessages: newAssistants,
            unreadCount: project.unreadCount,
            absoluteAssistantCount: result.canonicalAssistantCount ?? project.lastKnownUnreadCursor,
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
