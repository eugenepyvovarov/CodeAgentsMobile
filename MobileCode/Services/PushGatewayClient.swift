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
