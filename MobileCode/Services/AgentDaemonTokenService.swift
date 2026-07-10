//
//  AgentDaemonTokenService.swift
//  CodeAgentsMobile
//
//  Purpose: Per-server bearer tokens for the agent daemon HTTP API.
//

import Foundation
import Security

/// Manages CODEAGENTS_DAEMON_TOKEN for each Server (Keychain + remote env sync).
/// Not MainActor-bound: Keychain access is thread-safe enough for short reads/writes.
final class AgentDaemonTokenService: @unchecked Sendable {
    static let shared = AgentDaemonTokenService()

    private let lock = NSLock()

    private init() {}

    /// Return the stored token, or generate and store a new one.
    func token(for serverId: UUID) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let existing = try? KeychainManager.shared.retrieveDaemonToken(for: serverId),
           !existing.isEmpty {
            return existing
        }
        let generated = try generateToken()
        try KeychainManager.shared.storeDaemonToken(generated, for: serverId)
        return generated
    }

    /// Prefer stored token; optionally adopt a server-side value when local is missing.
    func resolveToken(for serverId: UUID, serverSide: String?) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let local = try? KeychainManager.shared.retrieveDaemonToken(for: serverId),
           !local.isEmpty {
            return local
        }
        if let serverSide, !serverSide.isEmpty {
            try KeychainManager.shared.storeDaemonToken(serverSide, for: serverId)
            return serverSide
        }
        let generated = try generateToken()
        try KeychainManager.shared.storeDaemonToken(generated, for: serverId)
        return generated
    }

    func authorizationHeaderValue(for serverId: UUID) -> String? {
        guard let token = try? KeychainManager.shared.retrieveDaemonToken(for: serverId),
              !token.isEmpty else {
            return nil
        }
        return "Bearer \(token)"
    }

    private func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw KeychainManager.KeychainError.unknown(status)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
