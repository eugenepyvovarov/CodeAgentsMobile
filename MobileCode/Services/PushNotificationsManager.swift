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
}

@MainActor
final class PushNotificationsManager: NSObject, ObservableObject {
    static let shared = PushNotificationsManager()

    @Published private(set) var currentFCMToken: String?

    private let gatewayClient = PushGatewayClient()
    private var modelContainer: ModelContainer?
    private var pendingPayload: PushPayload?

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
                await routeToChat(payload: payload)
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

    func handleLaunchOrTap(userInfo: [AnyHashable: Any]) {
        guard let payload = PushPayload(userInfo: userInfo) else { return }
        guard modelContainer != nil else {
            pendingPayload = payload
            return
        }
        Task {
            _ = await applyReplyFinishedUpdateIfPossible(payload: payload)
            await routeToChat(payload: payload)
        }
    }

    func handleRemoteNotification(userInfo: [AnyHashable: Any]) async -> Bool {
        guard let payload = PushPayload(userInfo: userInfo) else { return false }
        // Warm SSH as soon as a reply-finished push lands (even if user has not tapped yet).
        if payload.type == "reply_finished", let server = serverMatchingPush(payload: payload) {
            Task {
                await OpenCodeInstallerService.shared.warmConnection(for: server, probeHealth: true)
            }
        }
        return await applyReplyFinishedUpdateIfPossible(payload: payload)
    }

    func refreshSubscriptions() async {
        await reregisterAllStoredSubscriptionsIfPossible()
    }

    /// Call after APNs token is set so FCM issues a sendable iOS token.
    func refreshFCMTokenAfterAPNs() async {
        guard FirebaseBootstrap.configureIfNeeded() else { return }
        guard Messaging.messaging().apnsToken != nil else {
            #if DEBUG
            SSHLogger.log("Skipping FCM token refresh: APNs token not set yet", level: .warning)
            #endif
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Messaging.messaging().deleteToken { error in
                if let error {
                    SSHLogger.log(
                        "FCM deleteToken failed (continuing): \(error.localizedDescription)",
                        level: .warning
                    )
                }
                Messaging.messaging().token { token, tokenError in
                    if let tokenError {
                        SSHLogger.log(
                            "FCM token refresh failed: \(tokenError.localizedDescription)",
                            level: .warning
                        )
                    }
                    let resolved = token?.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { @MainActor in
                        if let resolved, !resolved.isEmpty {
                            self.currentFCMToken = resolved
                            #if DEBUG
                            SSHLogger.log(
                                "Refreshed FCM token after APNs: \(Self.redactedTokenDescription(resolved))",
                                level: .info
                            )
                            #endif
                        }
                        continuation.resume()
                    }
                }
            }
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
            guard let payload = PushPayload(userInfo: userInfo) else { continue }
            if await applyReplyFinishedUpdateIfPossible(payload: payload) {
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
        absoluteAssistantCount: Int
    ) async {
        let sessionId = project.openCodeSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sessionId, !sessionId.isEmpty else { return }

        let absolute = max(0, absoluteAssistantCount)

        if let cursors = AgentsListUnreadCursor.applyingAbsolute(
            lastKnown: project.lastKnownUnreadCursor,
            lastRead: project.lastReadUnreadCursor,
            unreadConversationId: project.unreadConversationId,
            sessionId: sessionId,
            absoluteAssistantCount: absolute
        ) {
            project.lastKnownUnreadCursor = cursors.lastKnown
            project.lastReadUnreadCursor = cursors.lastRead
            project.unreadConversationId = cursors.unreadConversationId
            project.noteLastMessage()
            project.updateLastModified()
            if let modelContainer {
                let context = ModelContext(modelContainer)
                // Project may be from a different context; persist via active store when possible.
                try? context.save()
            }
        }

        // If user is staring at this chat, keep counters honest but skip banners.
        if isViewingChat(for: project) {
            if project.unreadCount > 0 {
                // Viewing live stream: treat as read so the agents list stays clean.
                project.lastReadUnreadCursor = project.lastKnownUnreadCursor
            }
            if let modelContainer {
                UnreadBadgeService.refreshAppIconBadge(using: ModelContext(modelContainer))
            }
            return
        }

        if let modelContainer {
            UnreadBadgeService.refreshAppIconBadge(using: ModelContext(modelContainer))
        }

        let preview = Self.normalizedPreview(messagePreview)
        var gatewaySucceeded = false
        if let server,
           let secret = try? KeychainManager.shared.retrievePushSecret(for: server.id)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !secret.isEmpty {
            do {
                try await gatewayClient.triggerReplyFinished(
                    secret: secret,
                    payload: TriggerReplyFinishedPayload(
                        cwd: project.path,
                        conversationId: sessionId,
                        messagePreview: preview,
                        renderableAssistantCount: absolute
                    )
                )
                gatewaySucceeded = true
                #if DEBUG
                SSHLogger.log(
                    "Interactive reply_finished gateway ok for \(project.displayTitle)",
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

        // Local banner only when the gateway did not deliver (missing secret / network).
        // Successful gateway sends real FCM like scheduled jobs.
        if !gatewaySucceeded {
            await postLocalReplyFinishedNotification(
                project: project,
                server: server,
                title: agentDisplayName(for: project, server: server),
                body: preview ?? "Reply ready",
                conversationId: sessionId,
                absoluteAssistantCount: absolute
            )
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
        guard !isViewingChat(for: project) else { return }

        let sessionId = project.openCodeSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let server = fetchServer(withId: project.serverId)
        await postLocalReplyFinishedNotification(
            project: project,
            server: server,
            title: agentDisplayName(for: project, server: server),
            body: Self.normalizedPreview(preview) ?? "Reply ready",
            conversationId: sessionId,
            absoluteAssistantCount: project.lastKnownUnreadCursor
        )
    }

    // MARK: - Private

    /// True when the user is on Chat for this agent (suppress banners for that chat only).
    private func isViewingChat(for project: RemoteProject) -> Bool {
        guard AppNavigationState.shared.selectedTab == .chat,
              let active = ProjectContext.shared.activeProject else {
            return false
        }
        return active.id == project.id
    }

    private func agentDisplayName(for project: RemoteProject, server: Server?) -> String {
        if let server {
            return "\(project.displayTitle)@\(server.name)"
        }
        return project.displayTitle
    }

    private nonisolated static func normalizedPreview(_ text: String?, maxLen: Int = 160) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= maxLen { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: max(0, maxLen - 1))
        return String(collapsed[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private func postLocalReplyFinishedNotification(
        project: RemoteProject,
        server: Server?,
        title: String,
        body: String,
        conversationId: String?,
        absoluteAssistantCount: Int
    ) async {
        guard await hasNotificationDeliveryPermission() else { return }

        // Suppress only when user is inside this chat (same rule as FCM willPresent).
        if isViewingChat(for: project) { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = project.id.uuidString

        var userInfo: [AnyHashable: Any] = [
            "type": "reply_finished",
            "cwd": project.path,
            "local": "1",
        ]
        if let conversationId, !conversationId.isEmpty {
            userInfo["conversation_id"] = conversationId
        }
        if absoluteAssistantCount >= 0 {
            userInfo["renderable_assistant_count"] = String(absoluteAssistantCount)
        }
        if let server,
           let secret = try? KeychainManager.shared.retrievePushSecret(for: server.id)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !secret.isEmpty {
            userInfo["server_key"] = secret.sha256Hex()
        }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: "reply-finished-\(project.id.uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            // Drive the same in-app refresh path FCM uses (hydrate + badge).
            _ = await handleRemoteNotification(userInfo: userInfo)
        } catch {
            SSHLogger.log(
                "Local reply_finished notification failed: \(error.localizedDescription)",
                level: .warning
            )
        }
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
        let context = ModelContext(modelContainer)
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
        let context = ModelContext(modelContainer)
        let servers: [Server]
        do {
            servers = try context.fetch(FetchDescriptor<Server>())
        } catch {
            return nil
        }
        return servers.first { server in
            guard let secret = try? KeychainManager.shared.retrievePushSecret(for: server.id) else { return false }
            return secret.trimmingCharacters(in: .whitespacesAndNewlines).sha256Hex() == payload.serverKey
        }
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

    private func routeToChat(payload: PushPayload) async {
        guard let modelContainer else { return }
        let context = ModelContext(modelContainer)

        let servers: [Server]
        do {
            servers = try context.fetch(FetchDescriptor<Server>())
        } catch {
            return
        }

        guard let matchedServer = servers.first(where: { server in
            guard let secret = try? KeychainManager.shared.retrievePushSecret(for: server.id) else { return false }
            return secret.trimmingCharacters(in: .whitespacesAndNewlines).sha256Hex() == payload.serverKey
        }) else {
            return
        }

        let serverId = matchedServer.id
        let cwd = payload.cwd
        let descriptor = FetchDescriptor<RemoteProject>(
            predicate: #Predicate { project in
                project.serverId == serverId && project.path == cwd
            }
        )

        guard let project = (try? context.fetch(descriptor))?.first else {
            return
        }

        ProjectContext.shared.setActiveProject(project)
        AppNavigationState.shared.selectedTab = .chat

        // Kick off pooled OpenCode SSH + health before ChatView's connect loop so the
        // notification-open path reuses a warm session instead of a cold login.
        Task {
            await OpenCodeInstallerService.shared.warmConnection(for: matchedServer, probeHealth: true)
        }
    }

    @discardableResult
    private func applyReplyFinishedUpdateIfPossible(payload: PushPayload) async -> Bool {
        guard payload.type == "reply_finished" else { return false }
        guard let modelContainer else { return false }
        let context = ModelContext(modelContainer)

        let servers: [Server]
        do {
            servers = try context.fetch(FetchDescriptor<Server>())
        } catch {
            return false
        }

        guard let matchedServer = servers.first(where: { server in
            guard let secret = try? KeychainManager.shared.retrievePushSecret(for: server.id) else { return false }
            return secret.trimmingCharacters(in: .whitespacesAndNewlines).sha256Hex() == payload.serverKey
        }) else {
            return false
        }

        let serverId = matchedServer.id
        let cwd = payload.cwd
        let descriptor = FetchDescriptor<RemoteProject>(
            predicate: #Predicate { project in
                project.serverId == serverId && project.path == cwd
            }
        )

        guard let project = (try? context.fetch(descriptor))?.first else {
            return false
        }

        var didUpdateOpenCodeSession = false
        if CodingAgentRuntimeResolver.runtimeKind(for: project) == .openCode,
           project.applyOpenCodeSessionFromPush(payload.conversationId) {
            didUpdateOpenCodeSession = true
        }

        if let incomingCount = payload.renderableAssistantCount, incomingCount >= 0 {
            let isUnreadStateUninitialized =
                project.unreadConversationId == nil && project.lastKnownUnreadCursor == 0 && project.lastReadUnreadCursor == 0
            if isUnreadStateUninitialized {
                let baseline = min(estimateRenderableBubbleCount(for: project, in: context), incomingCount)
                project.lastKnownUnreadCursor = baseline
                project.lastReadUnreadCursor = baseline
            }

            if let conversationId = payload.conversationId, !conversationId.isEmpty {
                if project.unreadConversationId != conversationId {
                    let shouldResetReadCursor = project.unreadConversationId != nil && !isUnreadStateUninitialized
                    project.unreadConversationId = conversationId
                    if shouldResetReadCursor {
                        project.lastReadUnreadCursor = 0
                    }
                    project.lastKnownUnreadCursor = incomingCount
                } else if incomingCount > project.lastKnownUnreadCursor {
                    project.lastKnownUnreadCursor = incomingCount
                }
            } else if incomingCount > project.lastKnownUnreadCursor {
                project.lastKnownUnreadCursor = incomingCount
            }

            project.updateLastModified()

            do {
                try context.save()
            } catch {
                #if DEBUG
                SSHLogger.log("Failed to save unread update: \(error)", level: .warning)
                #endif
            }
        }

        if didUpdateOpenCodeSession {
            project.updateLastModified()
            do {
                try context.save()
            } catch {
                #if DEBUG
                SSHLogger.log("Failed to save OpenCode push session update: \(error)", level: .warning)
                #endif
            }
        }

        syncActiveProjectIfNeeded(from: project, payload: payload)
        postReplyFinishedEvent(project: project, server: matchedServer, payload: payload)
        // Always refresh app-icon total after cursor changes (background + other agents).
        refreshAppIconBadgeFromStore()
        return true
    }

    /// Recompute the home-screen badge from persisted agent unread cursors.
    private func refreshAppIconBadgeFromStore() {
        guard let modelContainer else { return }
        let context = ModelContext(modelContainer)
        UnreadBadgeService.refreshAppIconBadge(using: context)
    }

    private func syncActiveProjectIfNeeded(from project: RemoteProject, payload: PushPayload) {
        guard let activeProject = ProjectContext.shared.activeProject,
              activeProject.id == project.id else { return }

        var didUpdate = false
        if CodingAgentRuntimeResolver.runtimeKind(for: activeProject) == .openCode,
           activeProject.applyOpenCodeSessionFromPush(payload.conversationId) {
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

        guard didUpdate else { return }
        do {
            try modelContainer?.mainContext.save()
        } catch {
            #if DEBUG
            SSHLogger.log("Failed to save active project push sync: \(error)", level: .warning)
            #endif
        }
    }

    private func postReplyFinishedEvent(project: RemoteProject, server: Server, payload: PushPayload) {
        var userInfo: [String: Any] = [
            ReplyFinishedPushEventKey.projectId: project.id,
            ReplyFinishedPushEventKey.serverId: server.id,
            ReplyFinishedPushEventKey.cwd: payload.cwd,
        ]
        if let conversationId = payload.conversationId {
            userInfo[ReplyFinishedPushEventKey.conversationId] = conversationId
        }
        if let renderableAssistantCount = payload.renderableAssistantCount {
            userInfo[ReplyFinishedPushEventKey.renderableAssistantCount] = renderableAssistantCount
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

private struct PushPayload: Hashable {
    let type: String
    let serverKey: String
    let cwd: String
    let conversationId: String?
    let renderableAssistantCount: Int?

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
            self.renderableAssistantCount = count
        } else if let countString = countValue as? String, let count = Int(countString.trimmingCharacters(in: .whitespacesAndNewlines)) {
            self.renderableAssistantCount = count
        } else {
            self.renderableAssistantCount = nil
        }
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
            await self.reregisterAllStoredSubscriptionsIfPossible()
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
        handleLaunchOrTap(userInfo: response.notification.request.content.userInfo)
        completionHandler()
    }

    /// Suppress the system banner only for the agent chat the user is currently viewing.
    /// Background / other agents always surface banners + sound while the app is foregrounded.
    private func shouldSuppressForegroundNotification(payload: PushPayload) -> Bool {
        // Must be on the Chat tab of a live agent.
        guard AppNavigationState.shared.selectedTab == .chat,
              let activeProject = ProjectContext.shared.activeProject,
              let activeServer = ProjectContext.shared.activeServer else {
            return false
        }

        // Different agent path → always show (background chat replies).
        let activePath = activeProject.path.trimmingCharacters(in: .whitespacesAndNewlines)
        let payloadPath = payload.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !activePath.isEmpty, activePath == payloadPath else {
            return false
        }

        // Same path must also be on the same server (secret hash).
        guard let secret = try? KeychainManager.shared.retrievePushSecret(for: activeServer.id) else {
            return false
        }
        let matchesServer =
            secret.trimmingCharacters(in: .whitespacesAndNewlines).sha256Hex() == payload.serverKey
        return matchesServer
    }
}
