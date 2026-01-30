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

@MainActor
final class PushNotificationsManager: NSObject, ObservableObject {
    static let shared = PushNotificationsManager()

    @Published private(set) var currentFCMToken: String?

    private let gatewayClient = PushGatewayClient()
    private var modelContainer: ModelContainer?
    private var pendingPayload: PushPayload?

    private let subscriptionsStorageKey = "push_subscriptions_v1"

    private override init() {
        super.init()
    }

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        if let payload = pendingPayload {
            pendingPayload = nil
            Task {
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
        guard KeychainManager.shared.hasPushSecret(for: server.id) else {
            return
        }

        upsertStoredSubscription(.init(serverId: server.id, cwd: project.path, agentDisplayName: agentDisplayName))
        await registerStoredSubscriptionIfPossible(serverId: server.id, cwd: project.path, agentDisplayName: agentDisplayName)
    }

    func handleLaunchOrTap(userInfo: [AnyHashable: Any]) {
        guard let payload = PushPayload(userInfo: userInfo) else { return }
        guard modelContainer != nil else {
            pendingPayload = payload
            return
        }
        Task {
            await applyUnreadUpdateIfPossible(payload: payload)
            await routeToChat(payload: payload)
        }
    }

    func refreshSubscriptions() async {
        await reregisterAllStoredSubscriptionsIfPossible()
    }

    func syncDeliveredReplyFinishedNotifications() async {
        guard modelContainer != nil else { return }
        let center = UNUserNotificationCenter.current()
        let notifications: [UNNotification] = await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications)
            }
        }

        for notification in notifications {
            let userInfo = notification.request.content.userInfo
            guard let payload = PushPayload(userInfo: userInfo) else { continue }
            await applyUnreadUpdateIfPossible(payload: payload)
        }
    }

    // MARK: - Private

    private func redactedTokenDescription(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "<empty>"
        }
        let prefix = String(trimmed.prefix(10))
        let suffix = String(trimmed.suffix(6))
        return "\(trimmed.count) chars (\(prefix)…\(suffix))"
    }

    private func registerStoredSubscriptionIfPossible(serverId: UUID, cwd: String, agentDisplayName: String?) async {
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
                "Push subscription registered (cwd=\(cwd), token=\(redactedTokenDescription(token)))",
                level: .info
            )
            #endif
        } catch {
            SSHLogger.log("Push subscription registration failed: \(error)", level: .warning)
        }
    }

    private func fetchFCMToken() async -> String? {
        if let token = Messaging.messaging().fcmToken, !token.isEmpty {
            currentFCMToken = token
            #if DEBUG
            SSHLogger.log("Using cached FCM token: \(redactedTokenDescription(token))", level: .info)
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
                    SSHLogger.log("Fetched FCM token: \(self.redactedTokenDescription(resolved))", level: .info)
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
    }

    private func applyUnreadUpdateIfPossible(payload: PushPayload) async {
        guard payload.type == "reply_finished" else { return }
        guard let incomingCount = payload.renderableAssistantCount, incomingCount >= 0 else { return }
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
            SSHLogger.log("FCM token updated: \(redactedTokenDescription(token))", level: .info)
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

        Task { await applyUnreadUpdateIfPossible(payload: payload) }

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

    private func shouldSuppressForegroundNotification(payload: PushPayload) -> Bool {
        guard AppNavigationState.shared.selectedTab == .chat,
              let activeProject = ProjectContext.shared.activeProject,
              activeProject.path == payload.cwd,
              let activeServer = ProjectContext.shared.activeServer,
              let secret = try? KeychainManager.shared.retrievePushSecret(for: activeServer.id) else {
            return false
        }

        return secret.trimmingCharacters(in: .whitespacesAndNewlines).sha256Hex() == payload.serverKey
    }
}
