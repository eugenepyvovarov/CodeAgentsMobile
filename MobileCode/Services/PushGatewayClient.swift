//
//  PushGatewayClient.swift
//  CodeAgentsMobile
//
//  Purpose: HTTPS client for the Firebase Cloud Functions push gateway.
//

import Foundation
import FirebaseCore

enum PushGatewayError: LocalizedError {
    case firebaseNotConfigured
    case invalidURL
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .firebaseNotConfigured:
            return "Firebase is not configured (missing GoogleService-Info.plist)."
        case .invalidURL:
            return "Push gateway URL is invalid."
        case .requestFailed(let status):
            return "Push gateway request failed with status \(status)."
        }
    }
}

struct PushGatewayClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func functionsBaseURL() throws -> URL {
        guard let projectId = FirebaseApp.app()?.options.projectID, !projectId.isEmpty else {
            throw PushGatewayError.firebaseNotConfigured
        }
        guard let url = URL(string: "https://us-central1-\(projectId).cloudfunctions.net") else {
            throw PushGatewayError.invalidURL
        }
        return url
    }

    func registerSubscription(secret: String, payload: RegisterSubscriptionPayload) async throws {
        let url = try Self.functionsBaseURL().appendingPathComponent("registerSubscription")
        _ = try await sendJSON(to: url, secret: secret, payload: payload)
    }

    /// Remove this installation from the push gateway (all agents, or one cwd).
    func unregisterSubscription(secret: String, payload: UnregisterSubscriptionPayload) async throws {
        let url = try Self.functionsBaseURL().appendingPathComponent("unregisterSubscription")
        _ = try await sendJSON(to: url, secret: secret, payload: payload)
    }

    /// Same Cloud Function the CodeAgents daemon calls when a scheduled job finishes.
    /// Used by the app for interactive OpenCode replies that complete while the user is
    /// not watching that chat (agents list / other agent / background).
    func triggerReplyFinished(secret: String, payload: TriggerReplyFinishedPayload) async throws {
        let url = try Self.functionsBaseURL().appendingPathComponent("triggerReplyFinished")
        _ = try await sendJSON(to: url, secret: secret, payload: payload)
    }

    // MARK: - Private

    private func sendJSON<Payload: Encodable>(to url: URL, secret: String, payload: Payload) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PushGatewayError.requestFailed(status)
        }
        return data
    }
}

struct RegisterSubscriptionPayload: Codable {
    let cwd: String
    let installation_id: String
    let fcm_token: String
    let agent_display_name: String?
    let platform: String

    init(cwd: String, installationId: String, fcmToken: String, agentDisplayName: String?) {
        self.cwd = cwd
        self.installation_id = installationId
        self.fcm_token = fcmToken
        self.agent_display_name = agentDisplayName
        self.platform = "ios"
    }
}

struct UnregisterSubscriptionPayload: Codable {
    let installation_id: String
    let cwd: String?

    init(installationId: String, cwd: String? = nil) {
        self.installation_id = installationId
        self.cwd = cwd
    }
}

struct TriggerReplyFinishedPayload: Codable {
    let cwd: String
    let conversation_id: String?
    let message_preview: String?
    /// Legacy UI-bubble count retained for already-installed app builds.
    let renderable_assistant_count: Int?
    /// v2 absolute cursor: unique finalized, renderable OpenCode assistant messages.
    let assistant_message_cursor: Int?
    let cursor_version: Int?
    /// Gateway defaults lock-screen body to "Reply ready" unless this is true.
    let include_preview: Bool
    /// Omit only the installation that rendered this exact final interactive reply.
    let exclude_installation_id: String?
    /// Covers stale registrations when the installation document has not been stored yet.
    let exclude_fcm_token: String?
    /// Stable identity for deduping duplicate APNs callback paths on recipients.
    let completion_id: String?

    init(
        cwd: String,
        conversationId: String?,
        messagePreview: String?,
        legacyRenderableAssistantCount: Int?,
        assistantMessageCursor: Int? = nil,
        includePreview: Bool = false,
        excludeInstallationId: String? = nil,
        excludeFCMToken: String? = nil,
        completionId: String? = nil
    ) {
        self.cwd = cwd
        self.conversation_id = conversationId
        self.message_preview = messagePreview
        self.renderable_assistant_count = legacyRenderableAssistantCount
        self.assistant_message_cursor = assistantMessageCursor
        self.cursor_version = assistantMessageCursor == nil
            ? nil
            : OpenCodeUnreadCursorSchema.currentVersion
        self.include_preview = includePreview
        self.exclude_installation_id = excludeInstallationId
        self.exclude_fcm_token = excludeFCMToken
        self.completion_id = completionId
    }
}
