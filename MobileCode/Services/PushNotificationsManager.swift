//
//  PushNotificationsManager.swift
//  CodeAgentsMobile
//
//  Purpose: Manage FCM token lifecycle, agent subscriptions, and push deep-link routing.
//

import Foundation
import SwiftData
import UIKit
import UserNotifications
import FirebaseMessaging

extension Notification.Name {
    static let replyFinishedPushReceived = Notification.Name("replyFinishedPushReceived")
}

enum ReplyFinishedPushEventKey {
    static let projectId = "projectId"
    static let serverId = "serverId"
    static let cwd = "cwd"
    static let conversationId = "conversationId"
    static let renderableAssistantCount = "renderableAssistantCount"
    static let cursorVersion = "cursorVersion"
}

enum ReplyFinishedSessionRelationship: Equatable {
    case noIncomingSession
    case adoptable
    case matching
    case conflicting
}

enum ReplyFinishedSessionPolicy {
    static func relationship(currentSessionId: String?, incomingSessionId: String?) -> ReplyFinishedSessionRelationship {
        guard normalized(incomingSessionId) != nil else { return .noIncomingSession }
        guard let incoming = OpenCodeSessionID.sanitize(incomingSessionId) else {
            // Non-OpenCode/legacy task identifiers may still drive project refresh,
            // but are never authority to replace the live OpenCode chat session.
            return .noIncomingSession
        }
        let current = OpenCodeSessionID.sanitize(currentSessionId)
        guard let current else { return .adoptable }
        return current == incoming ? .matching : .conflicting
    }

    static func cursorSessionId(incomingSessionId: String?, incomingAssistantCount: Int?) -> String? {
        guard let incomingAssistantCount, incomingAssistantCount >= 0 else { return nil }
        return OpenCodeSessionID.sanitize(incomingSessionId)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ReplyFinishedTapDestination: Equatable {
    case chat
    case tasks
}

enum ReplyFinishedTapPolicy {
    static func destination(for relationship: ReplyFinishedSessionRelationship) -> ReplyFinishedTapDestination {
        switch relationship {
        case .adoptable, .matching:
            return .chat
        case .noIncomingSession, .conflicting:
            return .tasks
        }
    }
}

enum ReplyFinishedPresentationPolicy {
    static func shouldSuppress(
        applicationIsActive: Bool,
        isActiveChat: Bool,
        currentSessionId: String?,
        unreadConversationId: String?,
        payloadSessionId: String?,
        currentCursorVersion: Int? = OpenCodeUnreadCursorSchema.currentVersion,
        payloadCursorVersion: Int? = OpenCodeUnreadCursorSchema.currentVersion,
        lastReadCursor: Int,
        incomingAssistantCount: Int?
    ) -> Bool {
        guard applicationIsActive else { return false }

        let current = OpenCodeSessionID.sanitize(currentSessionId)
        let unread = OpenCodeSessionID.sanitize(unreadConversationId)
        let incoming = OpenCodeSessionID.sanitize(payloadSessionId)
        _ = isActiveChat

        // After the user navigates back, the durable read cursor is the evidence that
        // this exact session/count was already consumed before APNs arrived.
        guard currentCursorVersion == OpenCodeUnreadCursorSchema.currentVersion,
              payloadCursorVersion == OpenCodeUnreadCursorSchema.currentVersion,
              let current,
              let incoming,
              let unread,
              current == incoming,
              incoming == unread,
              let incomingAssistantCount,
              incomingAssistantCount >= 0 else {
            return false
        }
        return incomingAssistantCount <= max(0, lastReadCursor)
    }
}

@MainActor
protocol ReplyFinishedNotificationScheduling: AnyObject {
    func addReplyFinishedNotification(_ request: UNNotificationRequest) async throws
    func removePendingReplyFinishedNotifications(withIdentifiers identifiers: [String])
    func removeDeliveredReplyFinishedNotifications(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: ReplyFinishedNotificationScheduling {
    func addReplyFinishedNotification(_ request: UNNotificationRequest) async throws {
        try await add(request)
    }

    func removePendingReplyFinishedNotifications(withIdentifiers identifiers: [String]) {
        removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredReplyFinishedNotifications(withIdentifiers identifiers: [String]) {
        removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Serializes revocable local reply alerts so a read/dismiss that happens while
/// `UNUserNotificationCenter.add` is suspended cannot lose the cancellation race.
@MainActor
final class ReplyFinishedLocalNotificationCoordinator {
    private let center: ReplyFinishedNotificationScheduling
    private let defaults: UserDefaults
    private var activeIdentifiersByProject: [UUID: Set<String>] = [:]
    private let storageKey = "reply_finished_local_notification_ids_v1"

    init(
        center: ReplyFinishedNotificationScheduling = UNUserNotificationCenter.current(),
        defaults: UserDefaults = .standard
    ) {
        self.center = center
        self.defaults = defaults
        if let stored = defaults.dictionary(forKey: storageKey) as? [String: [String]] {
            activeIdentifiersByProject = stored.reduce(into: [:]) { result, entry in
                guard let projectID = UUID(uuidString: entry.key) else { return }
                result[projectID] = Set(entry.value)
            }
        }
    }

    @discardableResult
    func replace(
        projectID: UUID,
        request: UNNotificationRequest,
        isStillUnread: @MainActor @escaping () -> Bool
    ) async throws -> Bool {
        let previous = activeIdentifiersByProject[projectID] ?? []
        if !previous.isEmpty {
            remove(Array(previous))
        }
        activeIdentifiersByProject[projectID] = [request.identifier]
        persistIdentifiers()

        do {
            try await center.addReplyFinishedNotification(request)
        } catch {
            if activeIdentifiersByProject[projectID] == [request.identifier] {
                activeIdentifiersByProject.removeValue(forKey: projectID)
                persistIdentifiers()
            }
            throw error
        }

        guard activeIdentifiersByProject[projectID]?.contains(request.identifier) == true,
              isStillUnread() else {
            remove([request.identifier])
            if activeIdentifiersByProject[projectID] == [request.identifier] {
                activeIdentifiersByProject.removeValue(forKey: projectID)
                persistIdentifiers()
            }
            return false
        }
        return true
    }

    func dismiss(projectID: UUID) {
        var identifiers = activeIdentifiersByProject.removeValue(forKey: projectID) ?? []
        persistIdentifiers()
        // Remove the identifier used by builds before completion-specific IDs.
        identifiers.insert("reply-finished-\(projectID.uuidString)")
        remove(Array(identifiers))
    }

    private func remove(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removePendingReplyFinishedNotifications(withIdentifiers: identifiers)
        center.removeDeliveredReplyFinishedNotifications(withIdentifiers: identifiers)
    }

    private func persistIdentifiers() {
        let stored = activeIdentifiersByProject.reduce(into: [String: [String]]()) { result, entry in
            result[entry.key.uuidString] = Array(entry.value)
        }
        defaults.set(stored, forKey: storageKey)
    }
}

/// Produces a compact, plain-text notification preview without leaking
/// render-only `codeagents_ui` JSON into Notification Center.
enum NotificationPreviewText {
    static func normalize(_ text: String?, maxLength: Int = 160) -> String? {
        guard let text else { return nil }

        let segments = CodeAgentsUIBlockExtractor.segments(from: text)
        let prose = segments.compactMap { segment -> String? in
            guard case .markdown(let markdown) = segment else { return nil }
            let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let candidate: String
        if !prose.isEmpty {
            candidate = prose.joined(separator: "\n")
        } else if let widgetSummary = firstWidgetSummary(in: segments) {
            candidate = widgetSummary
        } else {
            return nil
        }

        let collapsed = candidate
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= maxLength { return collapsed }

        let end = collapsed.index(collapsed.startIndex, offsetBy: max(0, maxLength - 1))
        return String(collapsed[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func firstWidgetSummary(in segments: [CodeAgentsUIRenderSegment]) -> String? {
        for segment in segments {
            guard case .ui(let block) = segment else { continue }

            if let title = nonEmpty(block.title) {
                return title
            }

            for element in block.elements {
                if let summary = summary(for: element) {
                    return summary
                }
            }
        }
        return nil
    }

    private static func summary(for element: CodeAgentsUIElement) -> String? {
        switch element {
        case .card(let card):
            if let title = nonEmpty(card.title) { return title }
            if let subtitle = nonEmpty(card.subtitle) { return subtitle }
            return card.content.lazy.compactMap(summary).first
        case .markdown(let markdown):
            return nonEmpty(markdown.text)
        case .image(let image):
            return nonEmpty(image.caption) ?? nonEmpty(image.alt)
        case .gallery(let gallery):
            return nonEmpty(gallery.caption)
        case .video(let video):
            return nonEmpty(video.caption)
        case .table(let table):
            return nonEmpty(table.caption) ?? table.columns.lazy.compactMap(nonEmpty).first
        case .chart(let chart):
            return nonEmpty(chart.title) ?? nonEmpty(chart.subtitle)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
final class PushNotificationsManager: NSObject, ObservableObject {
    static let shared = PushNotificationsManager()

    @Published private(set) var currentFCMToken: String?

    private let gatewayClient = PushGatewayClient()
    private let subscriptionSyncCoordinator = PushSubscriptionSyncCoordinator()
    private let localNotificationCoordinator = ReplyFinishedLocalNotificationCoordinator()
    private var modelContainer: ModelContainer?
    private var pendingPayload: PushPayload?
    private var pendingLocalPayload: LocalReplyFinishedPayload?
    private var recentReplyFinishedDeliveryKeys: [String: Date] = [:]
    private var recentReplyFinishedPresentationKeys: [String: Date] = [:]

    private let replyFinishedDeliveryDedupeTTL: TimeInterval = 60 * 60
    private let replyFinishedDeliveryDedupeLimit = 384

    private let subscriptionsStorageKey = "push_subscriptions_v1"
    /// Avoid re-running full server SSH push provisioning on every foreground.
    private var lastAppDefaultPushAt: Date?
    private let appDefaultPushCooldown: TimeInterval = 5 * 60

    private override init() {
        super.init()
    }

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        if let payload = pendingPayload {
            pendingPayload = nil
            Task { @MainActor in
                _ = await applyReplyFinishedUpdateIfPossible(payload: payload)
                await routeTappedReply(payload: payload)
            }
        }
        if let payload = pendingLocalPayload {
            pendingLocalPayload = nil
            Task { @MainActor in
                await routeTappedLocalReply(payload)
            }
        }
    }

    func requestNotificationAuthorization() async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        @unknown default:
            return false
        }
    }

    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    func recordChatOpened(project: RemoteProject, server: Server, agentDisplayName: String) async {
        await registerProjectSubscription(project: project, server: server, agentDisplayName: agentDisplayName)
    }

    /// App-default push: request OS permission once, provision each server secret, and
    /// subscribe every agent. Opt-out is system Settings → Notifications → CodeAgents.
    func ensureAppDefaultPush(modelContext: ModelContext) async {
        if let last = lastAppDefaultPushAt,
           Date().timeIntervalSince(last) < appDefaultPushCooldown {
            await refreshSubscriptions()
            return
        }

        let granted: Bool
        do {
            granted = try await requestNotificationAuthorization()
        } catch {
            SSHLogger.log("Push permission request failed: \(error.localizedDescription)", level: .warning)
            return
        }
        guard granted else {
            #if DEBUG
            SSHLogger.log("Push skipped: notifications disabled in system Settings", level: .info)
            #endif
            return
        }

        registerForRemoteNotifications()

        let projects = (try? modelContext.fetch(FetchDescriptor<RemoteProject>())) ?? []
        let servers = (try? modelContext.fetch(FetchDescriptor<Server>())) ?? []
        guard !projects.isEmpty, !servers.isEmpty else { return }

        let serverById = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        var syncedServerIDs = Set<UUID>()

        for project in projects {
            guard let server = serverById[project.serverId] else { continue }
            let agentDisplayName = "\(project.displayTitle)@\(server.name)"
            upsertStoredSubscription(
                .init(serverId: server.id, cwd: project.path, agentDisplayName: agentDisplayName)
            )

            // One SSH push-config pass per server per ensure cycle.
            if syncedServerIDs.insert(server.id).inserted {
                await syncServerPushConfigurationIfPossible(server: server)
            }

            await registerStoredSubscriptionIfPossible(
                serverId: server.id,
                cwd: project.path,
                agentDisplayName: agentDisplayName,
                syncServer: false
            )
        }

        lastAppDefaultPushAt = Date()
    }

    func registerProjectSubscription(project: RemoteProject, server: Server, agentDisplayName: String) async {
        guard await hasNotificationDeliveryPermission() else {
            return
        }

        registerForRemoteNotifications()
        await syncServerPushConfigurationIfPossible(server: server)
        upsertStoredSubscription(.init(serverId: server.id, cwd: project.path, agentDisplayName: agentDisplayName))
        await registerStoredSubscriptionIfPossible(
            serverId: server.id,
            cwd: project.path,
            agentDisplayName: agentDisplayName,
            syncServer: false
        )
    }

    func handleLaunchOrTap(
        userInfo: [AnyHashable: Any],
        requestIdentifier: String? = nil
    ) {
        if let requestIdentifier,
           let localPayload = LocalReplyFinishedPayload(
               userInfo: userInfo,
               requestIdentifier: requestIdentifier
           ) {
            guard modelContainer != nil else {
                pendingLocalPayload = localPayload
                return
            }
            Task {
                await routeTappedLocalReply(localPayload)
            }
            return
        }
        guard let payload = PushPayload(userInfo: userInfo) else { return }
        guard modelContainer != nil else {
            pendingPayload = payload
            return
        }
        Task {
            _ = await applyReplyFinishedUpdateIfPossible(payload: payload)
            await routeTappedReply(payload: payload)
        }
    }

    func handleRemoteNotification(userInfo: [AnyHashable: Any]) async -> Bool {
        guard let payload = PushPayload(userInfo: userInfo) else { return false }
        guard claimReplyFinishedDeliveryIfNeeded(payload) else { return true }
        // Local requests are scheduled only after the source project cursor was saved.
        // Reapplying them as remote pushes would install a needless hydration gate.
        if payload.isLocal { return true }
        // Warm SSH as soon as a reply-finished push lands (even if user has not tapped yet).
        if payload.type == "reply_finished", let server = serverMatchingPush(payload: payload) {
            Task {
                await OpenCodeInstallerService.shared.warmConnection(for: server, probeHealth: true)
            }
        }
        return await applyReplyFinishedUpdateIfPossible(payload: payload)
    }

    func refreshSubscriptions() async {
        await subscriptionSyncCoordinator.request { [weak self] in
            guard let self else { return }
            await self.reregisterAllStoredSubscriptionsIfPossible()
        }
    }

    func syncDeliveredReplyFinishedNotifications() async {
        guard modelContainer != nil else { return }
        let center = UNUserNotificationCenter.current()
        let notifications: [UNNotification] = await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications)
            }
        }

        var didApply = false
        for notification in notifications {
            let userInfo = notification.request.content.userInfo
            if await handleRemoteNotification(userInfo: userInfo) {
                didApply = true
            }
        }
        // apply already refreshes badge; still recompute once if nothing applied so icon stays honest.
        if !didApply {
            refreshAppIconBadgeFromStore()
        }
    }

    /// Interactive OpenCode stream finished. When the user is not watching this chat,
    /// bump unread and fire the same `triggerReplyFinished` gateway path jobs use
    /// (local notification fallback if the gateway call fails).
    func notifyInteractiveReplyFinished(
        project: RemoteProject,
        server: Server?,
        messagePreview: String?,
        legacyRenderableAssistantCount: Int,
        absoluteAssistantCount: Int,
        wasFinalOutputSeen: Bool,
        completionId: String
    ) async {
        guard let sessionId = OpenCodeSessionID.sanitize(project.openCodeSessionId) else { return }

        if project.unreadCursorVersion != OpenCodeUnreadCursorSchema.currentVersion {
            project.unreadCursorVersion = OpenCodeUnreadCursorSchema.currentVersion
            project.unreadConversationId = nil
            project.lastKnownUnreadCursor = 0
            project.lastReadUnreadCursor = 0
        }

        let absolute = max(0, absoluteAssistantCount)
        if let cursors = AgentsListUnreadCursor.applyingInteractiveReplyFinished(
            lastKnown: project.lastKnownUnreadCursor,
            lastRead: project.lastReadUnreadCursor,
            unreadConversationId: project.unreadConversationId,
            sessionId: sessionId,
            absoluteAssistantCount: absolute,
            wasFinalOutputSeen: wasFinalOutputSeen
        ) {
            project.lastKnownUnreadCursor = cursors.lastKnown
            project.lastReadUnreadCursor = cursors.lastRead
            project.unreadConversationId = cursors.unreadConversationId
            project.noteLastMessage()
            project.updateLastModified()
        }

        // Mirror onto the active ProjectContext instance when it is the same agent
        // (background ModelContext saves do not always refresh the shared reference).
        syncActiveProjectUnreadCursors(from: project)

        // Persist the read cursor before awaiting the gateway. A self-FCM delivery can
        // otherwise race this method on another callback and resurrect an unread badge.
        if let modelContainer {
            do {
                try modelContainer.mainContext.save()
            } catch {
                SSHLogger.log(
                    "Failed to save interactive reply cursor: \(error.localizedDescription)",
                    level: .warning
                )
            }
            UnreadBadgeService.refreshAppIconBadge(using: modelContainer.mainContext)
        }

        let preview = Self.normalizedPreview(messagePreview)
        let sourceInstallationId: String?
        do {
            sourceInstallationId = try KeychainManager.shared.getOrCreatePushInstallationId()
        } catch {
            sourceInstallationId = nil
            SSHLogger.log(
                "Reply push skipped for other installations: installation identity unavailable",
                level: .warning
            )
        }

        // This installation never receives remote multicast for its own interactive
        // completion. A revocable local request handles its unread notification while
        // every other registered installation still receives FCM.
        if !wasFinalOutputSeen {
            await postLocalReplyFinishedNotification(
                project: project,
                server: server,
                title: agentDisplayName(for: project, server: server),
                body: preview ?? "Reply ready",
                conversationId: sessionId,
                legacyRenderableAssistantCount: legacyRenderableAssistantCount,
                absoluteAssistantCount: absolute,
                completionId: completionId
            )
        }

        // Notify every other registered installation through the gateway.
        if let server,
           let sourceInstallationId,
           let secret = try? KeychainManager.shared.retrievePushSecret(for: server.id)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !secret.isEmpty {
            let sourceFCMToken: String?
            if let currentFCMToken {
                sourceFCMToken = currentFCMToken
            } else {
                sourceFCMToken = await fetchFCMToken()
            }
            do {
                try await gatewayClient.triggerReplyFinished(
                    secret: secret,
                    payload: TriggerReplyFinishedPayload(
                        cwd: project.path,
                        conversationId: sessionId,
                        messagePreview: preview,
                        legacyRenderableAssistantCount: max(0, legacyRenderableAssistantCount),
                        assistantMessageCursor: absolute,
                        // Gateway ignores message_preview unless this is true (lock-screen default is "Reply ready").
                        includePreview: preview != nil,
                        excludeInstallationId: sourceInstallationId,
                        excludeFCMToken: sourceFCMToken,
                        completionId: completionId
                    )
                )
                #if DEBUG
                SSHLogger.log(
                    "Interactive reply_finished gateway ok for \(project.displayTitle) finalSeen=\(wasFinalOutputSeen) appState=\(UIApplication.shared.applicationState.rawValue)",
                    level: .info
                )
                #endif
            } catch {
                SSHLogger.log(
                    "Interactive reply_finished gateway failed: \(error.localizedDescription)",
                    level: .warning
                )
            }
        }

    }

    /// Soft-sync found higher unread for an agent the user is not viewing.
    func notifySoftSyncUnreadIncrease(
        project: RemoteProject,
        previousUnread: Int,
        newUnread: Int,
        preview: String?
    ) async {
        guard newUnread > previousUnread else { return }

        let sessionId = project.openCodeSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let server = fetchServer(withId: project.serverId)
        let legacyCount: Int
        if let modelContainer {
            legacyCount = estimateRenderableBubbleCount(for: project, in: modelContainer.mainContext)
        } else {
            legacyCount = project.lastKnownUnreadCursor
        }
        await postLocalReplyFinishedNotification(
            project: project,
            server: server,
            title: agentDisplayName(for: project, server: server),
            body: Self.normalizedPreview(preview) ?? "Reply ready",
            conversationId: sessionId,
            legacyRenderableAssistantCount: legacyCount,
            absoluteAssistantCount: project.lastKnownUnreadCursor
        )
    }

    // MARK: - Private

    /// True when the user is actively watching this agent's chat (suppress banners / mark-read).
    ///
    /// Requires the app to be **foreground-active**. Leaving the app (home, app switcher,
    /// another app) keeps Chat tab + active agent selection, but the user is no longer
    /// watching — so replies must still push and leave an unread badge.
    private func isViewingChat(for project: RemoteProject) -> Bool {
        Self.isActivelyViewingChat(
            projectId: project.id,
            selectedTab: AppNavigationState.shared.selectedTab,
            activeProjectId: ProjectContext.shared.activeProject?.id,
            applicationState: UIApplication.shared.applicationState
        )
    }

    /// Pure visibility rule used by interactive reply-finished + local banner suppress.
    nonisolated static func isActivelyViewingChat(
        projectId: UUID,
        selectedTab: AppTab,
        activeProjectId: UUID?,
        applicationState: UIApplication.State
    ) -> Bool {
        // Background / inactive: not watching, even if Chat is still the selected tab.
        guard applicationState == .active else { return false }
        guard selectedTab == .chat, let activeProjectId else { return false }
        return activeProjectId == projectId
    }

    private func agentDisplayName(for project: RemoteProject, server: Server?) -> String {
        if let server {
            return "\(project.displayTitle)@\(server.name)"
        }
        return project.displayTitle
    }

    private nonisolated static func normalizedPreview(_ text: String?, maxLen: Int = 160) -> String? {
        NotificationPreviewText.normalize(text, maxLength: maxLen)
    }

    private func postLocalReplyFinishedNotification(
        project: RemoteProject,
        server: Server?,
        title: String,
        body: String,
        conversationId: String?,
        legacyRenderableAssistantCount: Int,
        absoluteAssistantCount: Int,
        completionId: String? = nil
    ) async {
        guard await hasNotificationDeliveryPermission() else { return }

        let normalizedConversationId = conversationId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUnreadConversationId = project.unreadConversationId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedConversationId?.isEmpty == false,
           normalizedConversationId == normalizedUnreadConversationId,
           absoluteAssistantCount <= max(0, project.lastReadUnreadCursor) {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = project.id.uuidString

        var userInfo: [AnyHashable: Any] = [
            "type": "reply_finished",
            "cwd": project.path,
            "local": "1",
            "project_id": project.id.uuidString,
            "server_id": project.serverId.uuidString,
            "cursor_version": String(OpenCodeUnreadCursorSchema.currentVersion),
        ]
        if let conversationId, !conversationId.isEmpty {
            userInfo["conversation_id"] = conversationId
        }
        if legacyRenderableAssistantCount >= 0 {
            userInfo["renderable_assistant_count"] = String(legacyRenderableAssistantCount)
        }
        if absoluteAssistantCount >= 0 {
            userInfo["assistant_message_cursor"] = String(absoluteAssistantCount)
        }
        if let completionId, !completionId.isEmpty {
            userInfo["completion_id"] = completionId
        }
        if let server,
           let secret = try? KeychainManager.shared.retrievePushSecret(for: server.id)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !secret.isEmpty {
            userInfo["server_key"] = secret.sha256Hex()
        }
        content.userInfo = userInfo

        let requestIdentity = completionId ?? UUID().uuidString
        let request = UNNotificationRequest(
            identifier: "reply-finished-\(project.id.uuidString)-\(requestIdentity)",
            content: content,
            // Leave a short cancellation window so rendering/reading the final bubble
            // can revoke the request before the OS presents it.
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        do {
            let didSchedule = try await localNotificationCoordinator.replace(
                projectID: project.id,
                request: request,
                isStillUnread: {
                    let unreadConversationId = project.unreadConversationId?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let expectedConversationId = conversationId?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return expectedConversationId?.isEmpty != false
                        || unreadConversationId != expectedConversationId
                        || absoluteAssistantCount > max(0, project.lastReadUnreadCursor)
                }
            )
            guard didSchedule else { return }
        } catch {
            SSHLogger.log(
                "Local reply_finished notification failed: \(error.localizedDescription)",
                level: .warning
            )
        }
    }

    func dismissLocalReplyFinishedNotification(for projectID: UUID) {
        localNotificationCoordinator.dismiss(projectID: projectID)
    }

    private nonisolated static func redactedTokenDescription(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "<empty>"
        }
        let prefix = String(trimmed.prefix(10))
        let suffix = String(trimmed.suffix(6))
        return "\(trimmed.count) chars (\(prefix)…\(suffix))"
    }

    /// Best-effort remote unregister before deleting local push secrets / projects.
    func unregisterDevice(serverId: UUID, cwd: String? = nil) async {
        guard let secret = try? KeychainManager.shared.retrievePushSecret(for: serverId)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !secret.isEmpty else {
            return
        }
        let installationId: String
        do {
            installationId = try KeychainManager.shared.getOrCreatePushInstallationId()
        } catch {
            return
        }
        do {
            try await gatewayClient.unregisterSubscription(
                secret: secret,
                payload: UnregisterSubscriptionPayload(installationId: installationId, cwd: cwd)
            )
            #if DEBUG
            SSHLogger.log(
                "Push subscription unregistered (server=\(serverId.uuidString), cwd=\(cwd ?? "*"))",
                level: .info
            )
            #endif
        } catch {
            SSHLogger.log("Push subscription unregister failed: \(error)", level: .warning)
        }
    }

    private func registerStoredSubscriptionIfPossible(serverId: UUID, cwd: String, agentDisplayName: String?) async {
        await registerStoredSubscriptionIfPossible(
            serverId: serverId,
            cwd: cwd,
            agentDisplayName: agentDisplayName,
            syncServer: true
        )
    }

    private func registerStoredSubscriptionIfPossible(
        serverId: UUID,
        cwd: String,
        agentDisplayName: String?,
        syncServer: Bool
    ) async {
        if syncServer, let server = fetchServer(withId: serverId) {
            await syncServerPushConfigurationIfPossible(server: server)
        }

        guard let secret = try? KeychainManager.shared.retrievePushSecret(for: serverId).trimmingCharacters(in: .whitespacesAndNewlines),
              !secret.isEmpty else {
            return
        }

        guard let token = await fetchFCMToken(), !token.isEmpty else {
            return
        }

        let installationId: String
        do {
            installationId = try KeychainManager.shared.getOrCreatePushInstallationId()
        } catch {
            return
        }

        do {
            try await gatewayClient.registerSubscription(
                secret: secret,
                payload: RegisterSubscriptionPayload(
                    cwd: cwd,
                    installationId: installationId,
                    fcmToken: token,
                    agentDisplayName: agentDisplayName
                )
            )
            #if DEBUG
            SSHLogger.log(
                "Push subscription registered (cwd=\(cwd), token=\(Self.redactedTokenDescription(token)))",
                level: .info
            )
            #endif
        } catch {
            SSHLogger.log("Push subscription registration failed: \(error)", level: .warning)
        }
    }

    private func hasNotificationDeliveryPermission() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    private func syncServerPushConfigurationIfPossible(server: Server) async {
        let localSecret = (try? KeychainManager.shared.retrievePushSecret(for: server.id))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let result = try await ProxyInstallerService.shared.syncPushNotifications(
                on: server,
                preferredSecret: localSecret
            )
            try KeychainManager.shared.storePushSecret(result.secret, for: server.id)
            #if DEBUG
            SSHLogger.log("Push server sync completed: \(result.source)", level: .info)
            #endif
        } catch {
            SSHLogger.log("Push server sync failed: \(error)", level: .warning)
        }
    }

    private func fetchServer(withId serverId: UUID) -> Server? {
        guard let modelContainer else { return nil }
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Server>(
            predicate: #Predicate { server in
                server.id == serverId
            }
        )
        return (try? context.fetch(descriptor))?.first
    }

    /// Resolve the server that owns a push payload via hashed push secret.
    private func serverMatchingPush(payload: PushPayload) -> Server? {
        guard let modelContainer else { return nil }
        return serverMatchingPush(payload: payload, in: modelContainer.mainContext)
    }

    private func serverMatchingPush(payload: PushPayload, in context: ModelContext) -> Server? {
        guard let servers = try? context.fetch(FetchDescriptor<Server>()) else { return nil }
        return servers.first { server in
            guard let secret = try? KeychainManager.shared.retrievePushSecret(for: server.id) else { return false }
            return secret.trimmingCharacters(in: .whitespacesAndNewlines).sha256Hex() == payload.serverKey
        }
    }

    private func projectAndServerMatchingPush(
        payload: PushPayload,
        in context: ModelContext
    ) -> (project: RemoteProject, server: Server)? {
        guard let server = serverMatchingPush(payload: payload, in: context) else { return nil }
        let serverId = server.id
        let cwd = payload.cwd
        let descriptor = FetchDescriptor<RemoteProject>(
            predicate: #Predicate { project in
                project.serverId == serverId && project.path == cwd
            }
        )
        guard let project = (try? context.fetch(descriptor))?.first else { return nil }
        return (project, server)
    }

    private func claimReplyFinishedDeliveryIfNeeded(_ payload: PushPayload) -> Bool {
        guard payload.type == "reply_finished" else { return true }
        let keys = payload.deliveryDedupeKeys
        guard !keys.isEmpty else { return true }

        let now = Date()
        recentReplyFinishedDeliveryKeys = recentReplyFinishedDeliveryKeys.filter {
            now.timeIntervalSince($0.value) < replyFinishedDeliveryDedupeTTL
        }
        guard keys.allSatisfy({ recentReplyFinishedDeliveryKeys[$0] == nil }) else { return false }
        for key in keys {
            recentReplyFinishedDeliveryKeys[key] = now
        }

        if recentReplyFinishedDeliveryKeys.count > replyFinishedDeliveryDedupeLimit {
            let overflow = recentReplyFinishedDeliveryKeys.count - replyFinishedDeliveryDedupeLimit
            for staleKey in recentReplyFinishedDeliveryKeys
                .sorted(by: { $0.value < $1.value })
                .prefix(overflow)
                .map(\.key) {
                recentReplyFinishedDeliveryKeys.removeValue(forKey: staleKey)
            }
        }
        return true
    }

    /// Separate from state-delivery dedupe because AppDelegate may apply the same
    /// foreground push before UNUserNotificationCenter asks whether to present it.
    private func claimReplyFinishedPresentationIfNeeded(_ payload: PushPayload) -> Bool {
        guard payload.type == "reply_finished" else { return true }
        let keys = payload.deliveryDedupeKeys
        guard !keys.isEmpty else { return true }

        let now = Date()
        recentReplyFinishedPresentationKeys = recentReplyFinishedPresentationKeys.filter {
            now.timeIntervalSince($0.value) < replyFinishedDeliveryDedupeTTL
        }
        guard keys.allSatisfy({ recentReplyFinishedPresentationKeys[$0] == nil }) else { return false }
        for key in keys {
            recentReplyFinishedPresentationKeys[key] = now
        }

        if recentReplyFinishedPresentationKeys.count > replyFinishedDeliveryDedupeLimit {
            let overflow = recentReplyFinishedPresentationKeys.count - replyFinishedDeliveryDedupeLimit
            for staleKey in recentReplyFinishedPresentationKeys
                .sorted(by: { $0.value < $1.value })
                .prefix(overflow)
                .map(\.key) {
                recentReplyFinishedPresentationKeys.removeValue(forKey: staleKey)
            }
        }
        return true
    }

    private func fetchFCMToken() async -> String? {
        guard FirebaseBootstrap.configureIfNeeded() else {
            return nil
        }

        // Prefer not to register a token that was minted before APNs was wired up.
        if Messaging.messaging().apnsToken == nil {
            registerForRemoteNotifications()
            #if DEBUG
            SSHLogger.log("Deferring FCM token fetch until APNs token is available", level: .info)
            #endif
            return nil
        }

        if let token = Messaging.messaging().fcmToken, !token.isEmpty {
            currentFCMToken = token
            #if DEBUG
            SSHLogger.log("Using cached FCM token: \(Self.redactedTokenDescription(token))", level: .info)
            #endif
            return token
        }

        return await withCheckedContinuation { continuation in
            Messaging.messaging().token { token, error in
                if let error {
                    SSHLogger.log("FCM token fetch failed: \(error.localizedDescription)", level: .warning)
                }
                let resolved = token?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let resolved, !resolved.isEmpty {
                    Task { @MainActor in
                        self.currentFCMToken = resolved
                    }
                    #if DEBUG
                    SSHLogger.log("Fetched FCM token: \(Self.redactedTokenDescription(resolved))", level: .info)
                    #endif
                }
                continuation.resume(returning: resolved)
            }
        }
    }

    private func routeTappedReply(payload: PushPayload) async {
        guard let modelContainer else { return }
        let context = modelContainer.mainContext
        guard let match = projectAndServerMatchingPush(payload: payload, in: context) else { return }
        let project = match.project
        let matchedServer = match.server

        let relationship = ReplyFinishedSessionPolicy.relationship(
            currentSessionId: project.openCodeSessionId,
            incomingSessionId: payload.conversationId
        )
        let destination = ReplyFinishedTapPolicy.destination(for: relationship)

        routeToProject(project, server: matchedServer, destination: destination)
    }

    private func routeTappedLocalReply(_ payload: LocalReplyFinishedPayload) async {
        guard let modelContainer else { return }
        let context = modelContainer.mainContext
        let serverID = payload.serverID
        let projectID = payload.projectID
        let serverDescriptor = FetchDescriptor<Server>(
            predicate: #Predicate { server in server.id == serverID }
        )
        let projectDescriptor = FetchDescriptor<RemoteProject>(
            predicate: #Predicate { project in
                project.id == projectID && project.serverId == serverID
            }
        )
        guard let server = (try? context.fetch(serverDescriptor))?.first,
              let project = (try? context.fetch(projectDescriptor))?.first,
              project.path == payload.cwd else { return }

        let relationship = ReplyFinishedSessionPolicy.relationship(
            currentSessionId: project.openCodeSessionId,
            incomingSessionId: payload.conversationId
        )
        routeToProject(
            project,
            server: server,
            destination: ReplyFinishedTapPolicy.destination(for: relationship)
        )
    }

    private func routeToProject(
        _ project: RemoteProject,
        server: Server,
        destination: ReplyFinishedTapDestination
    ) {

        ProjectContext.shared.setActiveProject(project)
        AppNavigationState.shared.selectedTab = destination == .chat ? .chat : .tasks

        // Kick off pooled OpenCode SSH + health before ChatView's connect loop so the
        // notification-open path reuses a warm session instead of a cold login.
        Task {
            await OpenCodeInstallerService.shared.warmConnection(for: server, probeHealth: true)
        }
    }

    @discardableResult
    private func applyReplyFinishedUpdateIfPossible(payload: PushPayload) async -> Bool {
        guard payload.type == "reply_finished" else { return false }
        guard let modelContainer else { return false }
        let context = modelContainer.mainContext
        guard let match = projectAndServerMatchingPush(payload: payload, in: context) else { return false }
        let project = match.project
        let matchedServer = match.server

        let sessionRelationship = ReplyFinishedSessionPolicy.relationship(
            currentSessionId: project.openCodeSessionId,
            incomingSessionId: payload.conversationId
        )
        // A late completion from an older/different session may still present its
        // notification, but it must not replace or hydrate over the active chat. Emit
        // a project-only refresh so Regular Tasks still updates for daemon completions.
        if sessionRelationship == .conflicting || sessionRelationship == .noIncomingSession {
            postReplyFinishedEvent(
                project: project,
                server: matchedServer,
                payload: payload,
                includeConversationId: false
            )
            return true
        }

        var didChange = false
        if CodingAgentRuntimeResolver.runtimeKind(for: project) == .openCode,
           project.applyOpenCodeSessionFromPush(payload.conversationId) {
            didChange = true
        }

        if payload.cursorVersion == OpenCodeUnreadCursorSchema.currentVersion,
           let incomingCount = payload.renderableAssistantCount,
           let cursorSessionId = ReplyFinishedSessionPolicy.cursorSessionId(
               incomingSessionId: payload.conversationId,
               incomingAssistantCount: incomingCount
           ) {
            if project.unreadCursorVersion != OpenCodeUnreadCursorSchema.currentVersion {
                project.unreadCursorVersion = OpenCodeUnreadCursorSchema.currentVersion
                project.unreadConversationId = nil
                project.lastKnownUnreadCursor = 0
                project.lastReadUnreadCursor = 0
                didChange = true
            }
            let normalizedUnreadSession = project.unreadConversationId?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let wasAlreadyRead = normalizedUnreadSession == cursorSessionId
                && incomingCount <= max(0, project.lastReadUnreadCursor)

            // A duplicate/stale self-delivery must be a no-op. Feeding it through the
            // unseen reducer would reopen an unread gap the user already cleared.
            if !wasAlreadyRead,
               let cursors = AgentsListUnreadCursor.applyingInteractiveReplyFinished(
                   lastKnown: project.lastKnownUnreadCursor,
                   lastRead: project.lastReadUnreadCursor,
                   unreadConversationId: project.unreadConversationId,
                   sessionId: cursorSessionId,
                   absoluteAssistantCount: incomingCount,
                   wasFinalOutputSeen: false
               ) {
                let cursorDidChange = project.lastKnownUnreadCursor != cursors.lastKnown
                    || project.lastReadUnreadCursor != cursors.lastRead
                    || normalizedUnreadSession != cursors.unreadConversationId
                if cursorDidChange {
                    project.lastKnownUnreadCursor = cursors.lastKnown
                    project.lastReadUnreadCursor = cursors.lastRead
                    project.unreadConversationId = cursors.unreadConversationId
                    didChange = true
                }
            }
        }

        if didChange {
            project.updateLastModified()
            do {
                try context.save()
            } catch {
                #if DEBUG
                    SSHLogger.log("Failed to save reply-finished update: \(error)", level: .warning)
                #endif
            }
        }

        syncActiveProjectIfNeeded(from: project)
        postReplyFinishedEvent(project: project, server: matchedServer, payload: payload)
        // Always refresh app-icon total after cursor changes (background + other agents).
        refreshAppIconBadgeFromStore()
        return true
    }

    /// Recompute the home-screen badge from persisted agent unread cursors.
    private func refreshAppIconBadgeFromStore() {
        guard let modelContainer else { return }
        UnreadBadgeService.refreshAppIconBadge(using: modelContainer.mainContext)
    }

    /// Copy unread cursors onto the shared active project when IDs match.
    private func syncActiveProjectUnreadCursors(from project: RemoteProject) {
        guard let activeProject = ProjectContext.shared.activeProject,
              activeProject.id == project.id,
              activeProject !== project else { return }

        if activeProject.unreadConversationId != project.unreadConversationId {
            activeProject.unreadConversationId = project.unreadConversationId
        }
        if activeProject.lastKnownUnreadCursor != project.lastKnownUnreadCursor {
            activeProject.lastKnownUnreadCursor = project.lastKnownUnreadCursor
        }
        if activeProject.lastReadUnreadCursor != project.lastReadUnreadCursor {
            activeProject.lastReadUnreadCursor = project.lastReadUnreadCursor
        }
        if activeProject.unreadCursorVersion != project.unreadCursorVersion {
            activeProject.unreadCursorVersion = project.unreadCursorVersion
        }
    }

    private func syncActiveProjectIfNeeded(from project: RemoteProject) {
        guard let activeProject = ProjectContext.shared.activeProject,
              activeProject.id == project.id else { return }

        var didUpdate = false
        if CodingAgentRuntimeResolver.runtimeKind(for: activeProject) == .openCode,
           activeProject.applyOpenCodeSessionFromPush(project.openCodeSessionId) {
            didUpdate = true
        }

        if activeProject.unreadConversationId != project.unreadConversationId {
            activeProject.unreadConversationId = project.unreadConversationId
            didUpdate = true
        }
        if activeProject.lastKnownUnreadCursor != project.lastKnownUnreadCursor {
            activeProject.lastKnownUnreadCursor = project.lastKnownUnreadCursor
            didUpdate = true
        }
        if activeProject.lastReadUnreadCursor != project.lastReadUnreadCursor {
            activeProject.lastReadUnreadCursor = project.lastReadUnreadCursor
            didUpdate = true
        }
        if activeProject.unreadCursorVersion != project.unreadCursorVersion {
            activeProject.unreadCursorVersion = project.unreadCursorVersion
            didUpdate = true
        }

        guard didUpdate else { return }
        do {
            try modelContainer?.mainContext.save()
        } catch {
            #if DEBUG
            SSHLogger.log("Failed to save active project push sync: \(error)", level: .warning)
            #endif
        }
    }

    private func postReplyFinishedEvent(
        project: RemoteProject,
        server: Server,
        payload: PushPayload,
        includeConversationId: Bool = true
    ) {
        var userInfo: [String: Any] = [
            ReplyFinishedPushEventKey.projectId: project.id,
            ReplyFinishedPushEventKey.serverId: server.id,
            ReplyFinishedPushEventKey.cwd: payload.cwd,
        ]
        if includeConversationId, let conversationId = payload.conversationId {
            userInfo[ReplyFinishedPushEventKey.conversationId] = conversationId
        }
        if let renderableAssistantCount = payload.renderableAssistantCount {
            userInfo[ReplyFinishedPushEventKey.renderableAssistantCount] = renderableAssistantCount
        }
        if let cursorVersion = payload.cursorVersion {
            userInfo[ReplyFinishedPushEventKey.cursorVersion] = cursorVersion
        }
        NotificationCenter.default.post(name: .replyFinishedPushReceived, object: nil, userInfo: userInfo)
    }

    private func estimateRenderableBubbleCount(for project: RemoteProject, in context: ModelContext) -> Int {
        let projectId = project.id
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { message in
                message.projectId == projectId
            }
        )
        let messages: [Message]
        do {
            messages = try context.fetch(descriptor)
        } catch {
            return 0
        }

        var total = 0
        for message in messages {
            guard message.role == .assistant else { continue }

            if let structuredMessages = message.structuredMessages, !structuredMessages.isEmpty {
                for structured in structuredMessages {
                    switch structured.type {
                    case "assistant":
                        total += countRenderableBlocks(in: structured, includeText: true)
                    case "user":
                        total += countRenderableBlocks(in: structured, includeText: false)
                    default:
                        continue
                    }
                }
                continue
            }

            if let structured = message.structuredContent {
                switch structured.type {
                case "assistant":
                    total += countRenderableBlocks(in: structured, includeText: true)
                case "user":
                    total += countRenderableBlocks(in: structured, includeText: false)
                default:
                    break
                }
                continue
            }

            let fallbackBlocks = message.fallbackContentBlocks()
            if !fallbackBlocks.isEmpty {
                total += fallbackBlocks.reduce(0) { partial, block in
                    partial + renderableBlockIncrement(block, includeText: true)
                }
                continue
            }

            if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                total += 1
            }
        }

        return total
    }

    private func countRenderableBlocks(in structured: StructuredMessageContent, includeText: Bool) -> Int {
        guard let content = structured.message else { return 0 }
        switch content.content {
        case .blocks(let blocks):
            return blocks.reduce(0) { partial, block in
                partial + renderableBlockIncrement(block, includeText: includeText)
            }
        case .text(let text):
            guard includeText else { return 0 }
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
        }
    }

    private func renderableBlockIncrement(_ block: ContentBlock, includeText: Bool) -> Int {
        switch block {
        case .text(let textBlock):
            guard includeText else { return 0 }
            return textBlock.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
        case .toolUse, .toolResult:
            return 1
        case .unknown:
            return 0
        }
    }

    private func storedSubscriptions() -> [StoredSubscription] {
        guard let data = UserDefaults.standard.data(forKey: subscriptionsStorageKey) else {
            return []
        }
        return (try? JSONDecoder().decode([StoredSubscription].self, from: data)) ?? []
    }

    private func persistStoredSubscriptions(_ subscriptions: [StoredSubscription]) {
        guard let data = try? JSONEncoder().encode(subscriptions) else { return }
        UserDefaults.standard.set(data, forKey: subscriptionsStorageKey)
    }

    private func upsertStoredSubscription(_ subscription: StoredSubscription) {
        var current = storedSubscriptions()
        if let index = current.firstIndex(where: { $0.serverId == subscription.serverId && $0.cwd == subscription.cwd }) {
            current[index] = subscription
        } else {
            current.append(subscription)
        }
        persistStoredSubscriptions(current)
    }

    private func reregisterAllStoredSubscriptionsIfPossible() async {
        let current = storedSubscriptions()
        for subscription in current {
            await registerStoredSubscriptionIfPossible(
                serverId: subscription.serverId,
                cwd: subscription.cwd,
                agentDisplayName: subscription.agentDisplayName
            )
        }
    }
}

private struct StoredSubscription: Codable, Hashable {
    let serverId: UUID
    let cwd: String
    let agentDisplayName: String?
}

/// App-created local notifications can route without a provisioned server secret.
/// The request identifier is checked here so a remote payload cannot opt into this path.
struct LocalReplyFinishedPayload: Hashable {
    let projectID: UUID
    let serverID: UUID
    let cwd: String
    let conversationId: String?

    init?(userInfo: [AnyHashable: Any], requestIdentifier: String) {
        guard userInfo["type"] as? String == "reply_finished",
              userInfo["local"] as? String == "1",
              let projectIDString = userInfo["project_id"] as? String,
              let projectID = UUID(uuidString: projectIDString),
              let serverIDString = userInfo["server_id"] as? String,
              let serverID = UUID(uuidString: serverIDString),
              let cwd = userInfo["cwd"] as? String,
              !cwd.isEmpty else {
            return nil
        }

        let currentPrefix = "reply-finished-\(projectID.uuidString)-"
        let legacyIdentifier = "reply-finished-\(projectID.uuidString)"
        guard requestIdentifier.hasPrefix(currentPrefix) || requestIdentifier == legacyIdentifier else {
            return nil
        }

        self.projectID = projectID
        self.serverID = serverID
        self.cwd = cwd
        if let value = userInfo["conversation_id"] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            conversationId = trimmed.isEmpty ? nil : trimmed
        } else {
            conversationId = nil
        }
    }
}

struct PushPayload: Hashable {
    let type: String
    let serverKey: String
    let cwd: String
    let conversationId: String?
    /// Legacy UI-bubble count. Never use this as a v2 unread cursor.
    let legacyRenderableAssistantCount: Int?
    /// Canonical v2 absolute count of finalized, renderable assistant runtime messages.
    let assistantMessageCursor: Int?
    let cursorVersion: Int?
    let completionId: String?
    let deliveryId: String?
    let isLocal: Bool

    var deliveryDedupeKeys: [String] {
        var identities: [String] = []
        if let completionId {
            identities.append("completion:\(completionId)")
        }
        if let deliveryId {
            identities.append("delivery:\(deliveryId)")
        }
        if cursorVersion == OpenCodeUnreadCursorSchema.currentVersion,
           let conversationId = OpenCodeSessionID.sanitize(conversationId),
           let assistantMessageCursor,
           assistantMessageCursor >= 0 {
            // Correlate a soft-sync local fallback with a later daemon/APNs delivery
            // of the same canonical session/count even when the latter has its own ID.
            identities.append(
                "cursor-v\(OpenCodeUnreadCursorSchema.currentVersion):\(conversationId):\(assistantMessageCursor)"
            )
        }
        let prefix = "\(serverKey):\(cwd.sha256Hex()):"
        return identities.map { prefix + $0 }
    }

    var deliveryDedupeKey: String? { deliveryDedupeKeys.first }

    init?(userInfo: [AnyHashable: Any]) {
        guard let type = userInfo["type"] as? String,
              let serverKey = userInfo["server_key"] as? String,
              let cwd = userInfo["cwd"] as? String else {
            return nil
        }
        self.type = type
        self.serverKey = serverKey
        self.cwd = cwd

        if let conversationId = userInfo["conversation_id"] as? String {
            let trimmed = conversationId.trimmingCharacters(in: .whitespacesAndNewlines)
            self.conversationId = trimmed.isEmpty ? nil : trimmed
        } else {
            self.conversationId = nil
        }

        let countValue = userInfo["renderable_assistant_count"]
        if let count = countValue as? Int {
            self.legacyRenderableAssistantCount = count
        } else if let countString = countValue as? String, let count = Int(countString.trimmingCharacters(in: .whitespacesAndNewlines)) {
            self.legacyRenderableAssistantCount = count
        } else {
            self.legacyRenderableAssistantCount = nil
        }

        let cursorValue = userInfo["assistant_message_cursor"]
        if let cursor = cursorValue as? Int {
            self.assistantMessageCursor = cursor
        } else if let cursorString = cursorValue as? String,
                  let cursor = Int(cursorString.trimmingCharacters(in: .whitespacesAndNewlines)) {
            self.assistantMessageCursor = cursor
        } else {
            self.assistantMessageCursor = nil
        }

        // A legacy count accompanied by an optimistic version label is still legacy.
        // Accept v2 only when its distinct cursor field is present.
        let cursorVersionValue = userInfo["cursor_version"]
        if assistantMessageCursor != nil, let version = cursorVersionValue as? Int {
            self.cursorVersion = version
        } else if assistantMessageCursor != nil,
                  let versionString = cursorVersionValue as? String,
                  let version = Int(versionString.trimmingCharacters(in: .whitespacesAndNewlines)) {
            self.cursorVersion = version
        } else {
            self.cursorVersion = nil
        }

        self.completionId = Self.normalizedIdentifier(userInfo["completion_id"], maxLength: 128)
        self.deliveryId = Self.normalizedIdentifier(
            userInfo["gcm.message_id"] ?? userInfo["google.message_id"],
            maxLength: 256
        )
        self.isLocal = (userInfo["local"] as? String) == "1" || (userInfo["local"] as? Bool) == true
    }

    /// Compatibility name for internal call sites; now always means the v2 field.
    var renderableAssistantCount: Int? { assistantMessageCursor }

    private static func normalizedIdentifier(_ value: Any?, maxLength: Int) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return nil }
        return trimmed
    }
}

// MARK: - MessagingDelegate

extension PushNotificationsManager: @preconcurrency MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        let token = fcmToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !token.isEmpty else { return }

        Task { @MainActor in
            self.currentFCMToken = token
            #if DEBUG
            SSHLogger.log("FCM token updated: \(Self.redactedTokenDescription(token))", level: .info)
            #endif
            await self.refreshSubscriptions()
        }
    }
}

/// Coalesces token/subscription refresh requests without losing one that arrives during an active pass.
/// Firebase owns token rotation; this coordinator only serializes idempotent uploads of the current token.
actor PushSubscriptionSyncCoordinator {
    private var isRunning = false
    private var needsAnotherPass = false

    func request(_ operation: @escaping @Sendable () async -> Void) async {
        needsAnotherPass = true
        guard !isRunning else { return }

        isRunning = true
        defer { isRunning = false }

        while needsAnotherPass {
            needsAnotherPass = false
            await operation()
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension PushNotificationsManager: @preconcurrency UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        guard let payload = PushPayload(userInfo: userInfo),
              payload.type == "reply_finished" else {
            completionHandler([.banner, .list, .sound, .badge])
            return
        }

        guard claimReplyFinishedPresentationIfNeeded(payload) else {
            completionHandler([])
            return
        }

        Task { _ = await handleRemoteNotification(userInfo: userInfo) }

        if shouldSuppressForegroundNotification(payload: payload) {
            completionHandler([])
            return
        }

        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleLaunchOrTap(
            userInfo: response.notification.request.content.userInfo,
            requestIdentifier: response.notification.request.identifier
        )
        completionHandler()
    }

    /// Suppress a foreground banner when the matching chat is open, or when the
    /// persisted cursor proves this exact session/count was already read before APNs arrived.
    private func shouldSuppressForegroundNotification(payload: PushPayload) -> Bool {
        let applicationIsActive = UIApplication.shared.applicationState == .active
        guard let modelContainer,
              let match = projectAndServerMatchingPush(
                  payload: payload,
                  in: modelContainer.mainContext
              ) else {
            return false
        }

        let storedProject = match.project
        let activeProject = ProjectContext.shared.activeProject
        let isActiveChat = AppNavigationState.shared.selectedTab == .chat
            && activeProject?.id == storedProject.id
        let currentProject = isActiveChat ? activeProject ?? storedProject : storedProject

        return ReplyFinishedPresentationPolicy.shouldSuppress(
            applicationIsActive: applicationIsActive,
            isActiveChat: isActiveChat,
            currentSessionId: currentProject.openCodeSessionId,
            unreadConversationId: currentProject.unreadConversationId,
            payloadSessionId: payload.conversationId,
            currentCursorVersion: currentProject.unreadCursorVersion,
            payloadCursorVersion: payload.cursorVersion,
            lastReadCursor: currentProject.lastReadUnreadCursor,
            incomingAssistantCount: payload.renderableAssistantCount
        )
    }
}
